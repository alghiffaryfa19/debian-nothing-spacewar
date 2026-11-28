#!/usr/bin/env bash
# Convert prebuilt Arch Linux Droidloom packages (.pkg.tar.zst) into Debian (.deb) packages,
# including the unshare --forward-signals wrapper and optional droidloom-gapps .deb.
set -euo pipefail

BUILD_BASE_IMAGE=1
BUILD_RUNTIME=1
BUILD_GAPPS=1
CHROOT_DIR=""
LITEGAPPS_URL="${LITEGAPPS_URL:-https://sourceforge.net/projects/litegapps/files/litegapps/arm64/37/lite/2026-10-12/LiteGapps-arm64-17.0-20261012-official.zip/download}"

while (($#)); do
  case "$1" in
    --runtime-only)
      BUILD_BASE_IMAGE=0
      shift
      ;;
    --no-gapps)
      BUILD_GAPPS=0
      shift
      ;;
    --gapps-only)
      BUILD_BASE_IMAGE=0
      BUILD_RUNTIME=0
      BUILD_GAPPS=1
      shift
      ;;
    --chroot)
      (($# >= 2)) || { echo "Missing value for --chroot" >&2; exit 1; }
      CHROOT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--runtime-only] [--no-gapps] [--gapps-only] [--chroot DIR]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${DROIDLOOM_CACHE_DIR:-${SCRIPT_DIR}/.work/cache/droidloom}"
OUT_DIR="${DROIDLOOM_DEB_DIR:-${SCRIPT_DIR}/debs}"
WORK_DIR=""

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  aarch64)
    PACMAN_ARCH="aarch64"
    DEB_ARCH="arm64"
    ;;
  x86_64)
    PACMAN_ARCH="x86_64"
    DEB_ARCH="amd64"
    ;;
  *)
    echo "Unsupported architecture: $HOST_ARCH (expected aarch64 or x86_64)" >&2
    exit 1
    ;;
esac

for cmd in curl tar zstd dpkg-deb sha256sum gcc; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

mkdir -p "$CACHE_DIR" "$OUT_DIR"
WORK_DIR="$(mktemp -d "${SCRIPT_DIR}/.work-dl.XXXXXX")"

DB_URL="https://denialwm.github.io/droidloom/${PACMAN_ARCH}/droidloom.db"
PKG_BASE_URL="https://github.com/denialwm/droidloom/releases/download/packages"

echo "==> Fetching Droidloom pacman database (${PACMAN_ARCH})..."
curl -fsSL "$DB_URL" -o "${WORK_DIR}/droidloom.db"
mkdir -p "${WORK_DIR}/db"
tar -xf "${WORK_DIR}/droidloom.db" -C "${WORK_DIR}/db"

declare -A PKG_FILE PKG_VER PKG_SHA PKG_DESC PKG_ISIZE

for pkg in droidloom-base droidloom-image droidloom-runtime; do
  desc_file="$(find "${WORK_DIR}/db" -maxdepth 2 -name desc -path "*/${pkg}-*" | head -n 1)"
  if [[ -z "$desc_file" || ! -f "$desc_file" ]]; then
    echo "Package ${pkg} not found in pacman database" >&2
    exit 1
  fi
  PKG_FILE[$pkg]="$(awk '/^%FILENAME%$/{getline; print; exit}' "$desc_file")"
  PKG_VER[$pkg]="$(awk '/^%VERSION%$/{getline; print; exit}' "$desc_file")"
  PKG_SHA[$pkg]="$(awk '/^%SHA256SUM%$/{getline; print; exit}' "$desc_file")"
  PKG_DESC[$pkg]="$(awk '/^%DESC%$/{getline; print; exit}' "$desc_file")"
  PKG_ISIZE[$pkg]="$(awk '/^%ISIZE%$/{getline; print; exit}' "$desc_file")"
  echo "    ${pkg} ${PKG_VER[$pkg]} -> ${PKG_FILE[$pkg]}"
done

if (( BUILD_BASE_IMAGE || BUILD_RUNTIME )); then
  for pkg in droidloom-base droidloom-image droidloom-runtime; do
    if (( !BUILD_BASE_IMAGE )) && [[ "$pkg" != "droidloom-runtime" ]]; then
      continue
    fi
    fname="${PKG_FILE[$pkg]}"
    target="${CACHE_DIR}/${fname}"
    expected_sha="${PKG_SHA[$pkg]}"
    if [[ -f "$target" ]]; then
      actual_sha="$(sha256sum "$target" | awk '{print $1}')"
      if [[ "$actual_sha" == "$expected_sha" ]]; then
        echo "==> Using cached ${fname} (SHA256 verified)"
      else
        echo "==> Cached ${fname} checksum mismatch; re-downloading..."
        rm -f "$target"
      fi
    fi
    if [[ ! -f "$target" ]]; then
      echo "==> Downloading ${fname}..."
      curl -fL --retry 3 --progress-bar "${PKG_BASE_URL}/${fname}" -o "${target}.part"
      mv "${target}.part" "$target"
      actual_sha="$(sha256sum "$target" | awk '{print $1}')"
      if [[ "$actual_sha" != "$expected_sha" ]]; then
        echo "SHA256 mismatch for ${fname}: expected ${expected_sha}, got ${actual_sha}" >&2
        exit 1
      fi
    fi
  done

  # Extract base_ver dependency from droidloom-image .PKGINFO
  IMAGE_DEP_BASE="$(tar --zstd -xOf "${CACHE_DIR}/${PKG_FILE[droidloom-image]}" .PKGINFO | awk -F' = ' '/^depend = droidloom-base=/{sub(/^droidloom-base=/, "", $2); print $2; exit}')"
  if [[ -z "$IMAGE_DEP_BASE" ]]; then
    IMAGE_DEP_BASE="${PKG_VER[droidloom-base]}"
  fi
fi

build_deb() {
  local pkg="$1"
  local depends="$2"
  local recommends="$3"
  local ver="${PKG_VER[$pkg]}"
  local fname="${PKG_FILE[$pkg]}"
  local stage="${WORK_DIR}/stage-${pkg}"
  local installed_kb=$(( (${PKG_ISIZE[$pkg]} + 1023) / 1024 ))

  echo "==> Staging ${pkg}_${ver}_${DEB_ARCH}.deb..."
  mkdir -p "${stage}/DEBIAN"
  tar --zstd -xf "${CACHE_DIR}/${fname}" -C "$stage"

  # Remove Arch pacman metadata and alpm hooks
  rm -f "${stage}/.PKGINFO" "${stage}/.MTREE" "${stage}/.BUILDINFO" "${stage}/.INSTALL" "${stage}/.CHANGELOG"
  rm -rf "${stage}/usr/share/libalpm"

  cat > "${stage}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${ver}
Architecture: ${DEB_ARCH}
Maintainer: Droidloom Debian Wrapper <noreply@github.com>
Installed-Size: ${installed_kb}
Section: misc
Priority: optional
Homepage: https://github.com/denialwm/droidloom
Description: ${PKG_DESC[$pkg]}
 Repackaged from the official Arch Linux (${PACMAN_ARCH}) prebuilt archive
 for Debian (${DEB_ARCH}).
EOF

  if [[ -n "$depends" ]]; then
    echo "Depends: ${depends}" >> "${stage}/DEBIAN/control"
  fi
  if [[ -n "$recommends" ]]; then
    echo "Recommends: ${recommends}" >> "${stage}/DEBIAN/control"
  fi

  if [[ "$pkg" == "droidloom-runtime" ]]; then
    # Debian's util-linux lacks unshare --forward-signals.
    # Provide a small wrapper in /usr/lib/droidloom/bin/unshare and prepend it to droidloomd.service PATH.
    mkdir -p "${stage}/usr/lib/droidloom/bin" "${stage}/usr/lib/systemd/system/droidloomd.service.d"
    cat > "${WORK_DIR}/unshare-wrapper.c" <<'CEOF'
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile pid_t child_pid = -1;

static void forward_sig(int sig) {
  if (child_pid > 0) {
    kill(child_pid, sig);
  }
}

int main(int argc, char **argv) {
  char **new_argv = calloc((size_t)argc + 1, sizeof(char *));
  if (!new_argv) return 127;

  int forward_signals = 0;
  int j = 0;
  new_argv[j++] = "/usr/bin/unshare";
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--forward-signals") == 0) {
      forward_signals = 1;
      continue;
    }
    new_argv[j++] = argv[i];
  }
  new_argv[j] = NULL;

  if (!forward_signals) {
    execv("/usr/bin/unshare", new_argv);
    perror("execv /usr/bin/unshare");
    return 127;
  }

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = forward_sig;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGHUP, &sa, NULL);
  sigaction(SIGQUIT, &sa, NULL);

  pid_t pid = fork();
  if (pid < 0) {
    perror("fork");
    return 127;
  }
  if (pid == 0) {
    execv("/usr/bin/unshare", new_argv);
    perror("execv /usr/bin/unshare");
    _exit(127);
  }
  child_pid = pid;

  int status = 0;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) return 127;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) {
    signal(WTERMSIG(status), SIG_DFL);
    raise(WTERMSIG(status));
    return 128 + WTERMSIG(status);
  }
  return 1;
}
CEOF
    gcc -O2 -Wall -Wextra -o "${stage}/usr/lib/droidloom/bin/unshare" "${WORK_DIR}/unshare-wrapper.c"
    chmod 0755 "${stage}/usr/lib/droidloom/bin/unshare"

    cat > "${stage}/usr/lib/systemd/system/droidloomd.service.d/debian-unshare-path.conf" <<'EOF'
[Service]
Environment=PATH=/usr/lib/droidloom/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF

    cat > "${stage}/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
HELPER="/usr/lib/droidloom/droidloom-package-helper"
if [ -x "$HELPER" ]; then
  case "$1" in
    remove)
      "$HELPER" before-remove || true
      ;;
    upgrade)
      "$HELPER" before-upgrade || true
      ;;
  esac
fi
EOF
    chmod 0755 "${stage}/DEBIAN/prerm"

    cat > "${stage}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
HELPER="/usr/lib/droidloom/droidloom-package-helper"
if [ "$1" = "configure" ]; then
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
  fi
  if [ -x "$HELPER" ]; then
    "$HELPER" after-install
  fi
fi
EOF
    chmod 0755 "${stage}/DEBIAN/postinst"
  else
    cat > "${stage}/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
HELPER="/usr/lib/droidloom/droidloom-package-helper"
if [ -x "$HELPER" ] && [ "$1" = "upgrade" ]; then
  "$HELPER" before-upgrade || true
fi
EOF
    chmod 0755 "${stage}/DEBIAN/prerm"
  fi

  local deb_path="${OUT_DIR}/${pkg}_${ver}_${DEB_ARCH}.deb"
  dpkg-deb --build --root-owner-group "$stage" "$deb_path"
  rm -rf "$stage"
}

build_gapps_deb() {
  if [[ -n "${SUDO_USER:-}" && -d "/home/${SUDO_USER}/.cargo/bin" ]]; then
    export PATH="/home/${SUDO_USER}/.cargo/bin:$PATH"
  fi
  if [[ -d "/root/.cargo/bin" ]]; then
    export PATH="/root/.cargo/bin:$PATH"
  fi
  command -v cargo >/dev/null 2>&1 || { echo "Missing required command: cargo" >&2; exit 1; }

  local dl_ver="${PKG_VER[droidloom-runtime]}"
  local gapps_zip="${CACHE_DIR}/LiteGapps-arm64-17.0-20261012-official.zip"
  if [[ ! -s "$gapps_zip" ]]; then
    echo "==> Downloading LiteGapps archive..."
    curl -fL --retry 3 -o "${gapps_zip}.part" "$LITEGAPPS_URL"
    mv -f "${gapps_zip}.part" "$gapps_zip"
  fi
  local gapps_sha256
  gapps_sha256="$(sha256sum "$gapps_zip" | awk '{print $1}')"

  local src_tar="${CACHE_DIR}/droidloom-source-${dl_ver}.tar.gz"
  if [[ ! -s "$src_tar" ]]; then
    echo "==> Downloading droidloom-source-${dl_ver}.tar.gz..."
    curl -fL --retry 3 -o "${src_tar}.part" "${PKG_BASE_URL}/droidloom-source-${dl_ver}.tar.gz"
    mv -f "${src_tar}.part" "$src_tar"
  fi

  local src_dir="${WORK_DIR}/droidloom-src"
  local addon_dir="${WORK_DIR}/gapps-arm64"
  mkdir -p "$src_dir"
  tar -xzf "$src_tar" -C "$src_dir"

  echo "==> Building droidloom-gapps binary..."
  (
    cd "${src_dir}/droidloom"
    cargo build --locked -j 1 -p droidloom-gapps
  )
  local gapps_bin="${src_dir}/droidloom/target/debug/droidloom-gapps"
  [[ -x "$gapps_bin" ]] || { echo "Failed to build droidloom-gapps" >&2; exit 1; }

  if [[ -n "$CHROOT_DIR" ]]; then
    echo "==> Running droidloom-gapps inside Debian chroot (${CHROOT_DIR})..."
    DEBIAN_FRONTEND=noninteractive chroot "$CHROOT_DIR" apt-get install -y aapt apksigner
    install -Dm755 "$gapps_bin" "${CHROOT_DIR}/tmp/droidloom-gapps"
    cp -f "$gapps_zip" "${CHROOT_DIR}/tmp/LiteGapps.zip"
    rm -rf "${CHROOT_DIR}/tmp/gapps-arm64"
    chroot "$CHROOT_DIR" /tmp/droidloom-gapps inspect /tmp/LiteGapps.zip
    chroot "$CHROOT_DIR" /tmp/droidloom-gapps build \
      --archive /tmp/LiteGapps.zip \
      --sha256 "$gapps_sha256" \
      --base /usr/lib/droidloom/images \
      --output /tmp/gapps-arm64 \
      --aapt2 /usr/bin/aapt2 \
      --apksigner /usr/bin/apksigner
    chroot "$CHROOT_DIR" /tmp/droidloom-gapps verify \
      --addon /tmp/gapps-arm64 \
      --base /usr/lib/droidloom/images
    mv "${CHROOT_DIR}/tmp/gapps-arm64" "$addon_dir"
    rm -f "${CHROOT_DIR}/tmp/droidloom-gapps" "${CHROOT_DIR}/tmp/LiteGapps.zip"
    DEBIAN_FRONTEND=noninteractive chroot "$CHROOT_DIR" apt-get purge -y --auto-remove aapt apksigner
  else
    for cmd in aapt2 apksigner dump.erofs fsck.erofs mkfs.erofs getfattr setfattr fakeroot; do
      command -v "$cmd" >/dev/null || { echo "Missing host command for GApps build: $cmd" >&2; exit 1; }
    done
    local base_dir="${WORK_DIR}/base-images"
    mkdir -p "$base_dir"
    tar --zstd -xf "${CACHE_DIR}/${PKG_FILE[droidloom-base]}" -C "$base_dir" usr/lib/droidloom/images
    tar --zstd -xf "${CACHE_DIR}/${PKG_FILE[droidloom-image]}" -C "$base_dir" usr/lib/droidloom/images
    "$gapps_bin" inspect "$gapps_zip"
    "$gapps_bin" build \
      --archive "$gapps_zip" \
      --sha256 "$gapps_sha256" \
      --base "${base_dir}/usr/lib/droidloom/images" \
      --output "$addon_dir" \
      --aapt2 "$(command -v aapt2)" \
      --apksigner "$(command -v apksigner)"
    "$gapps_bin" verify \
      --addon "$addon_dir" \
      --base "${base_dir}/usr/lib/droidloom/images"
    rm -rf "$base_dir"
  fi

  local gapps_ver
  gapps_ver="$(awk -F'"' '/"upstream_version"/{print $4; exit}' "${addon_dir}/manifest.json")"
  gapps_ver="${gapps_ver:-20261012}-1"
  # Ensure version starts with a digit for dpkg-deb
  if [[ ! "$gapps_ver" =~ ^[0-9] ]]; then
    gapps_ver="0.${gapps_ver}"
  fi

  local stage="${WORK_DIR}/stage-droidloom-gapps"
  mkdir -p "${stage}/DEBIAN" "${stage}/usr/lib/droidloom/addons/gapps/images" "${stage}/usr/share/licenses/droidloom-gapps"
  for item in manifest.json import-report.json LICENSE.LiteGapps NOTICE images/product.img images/system_ext.img; do
    cp --reflink=auto --sparse=always -- "${addon_dir}/${item}" "${stage}/usr/lib/droidloom/addons/gapps/${item}"
  done
  cp -- "${addon_dir}/LICENSE.LiteGapps" "${stage}/usr/share/licenses/droidloom-gapps/LICENSE.LiteGapps"
  cp -- "${addon_dir}/NOTICE" "${stage}/usr/share/licenses/droidloom-gapps/NOTICE"

  local installed_kb
  installed_kb="$(du -sk "${stage}/usr" | awk '{print $1}')"
  cat > "${stage}/DEBIAN/control" <<EOF
Package: droidloom-gapps
Version: ${gapps_ver}
Architecture: ${DEB_ARCH}
Maintainer: Droidloom Debian Wrapper <noreply@github.com>
Installed-Size: ${installed_kb}
Section: misc
Priority: optional
Depends: droidloom-runtime, droidloom-image
Homepage: https://github.com/denialwm/droidloom
Description: Optional locally imported Google apps for Droidloom Android 17
 LiteGapps regular lite add-on built and verified with droidloom-gapps.
EOF

  cat > "${stage}/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
HELPER="/usr/lib/droidloom/droidloom-package-helper"
if [ -x "$HELPER" ]; then
  "$HELPER" before-upgrade || true
fi
EOF
  chmod 0755 "${stage}/DEBIAN/prerm"

  cat > "${stage}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  chown -R 0:0 /usr/lib/droidloom/addons/gapps
  chmod 0755 /usr/lib/droidloom/addons /usr/lib/droidloom/addons/gapps /usr/lib/droidloom/addons/gapps/images
  chmod -R go-w /usr/lib/droidloom/addons/gapps
fi
EOF
  chmod 0755 "${stage}/DEBIAN/postinst"

  local deb_path="${OUT_DIR}/droidloom-gapps_${gapps_ver}_${DEB_ARCH}.deb"
  dpkg-deb --build --root-owner-group "$stage" "$deb_path"
  rm -rf "$stage" "$addon_dir" "$src_dir"
  echo "==> Built GApps package: ${deb_path}"
}

if (( BUILD_BASE_IMAGE )); then
  build_deb "droidloom-base" "" ""
  build_deb "droidloom-image" "droidloom-base (= ${IMAGE_DEP_BASE})" ""
fi

if (( BUILD_RUNTIME )); then
  RUNTIME_DEPENDS="droidloom-image (= ${PKG_VER[droidloom-image]}), libc6, libgcc-s1, libgbm1, libegl-mesa0, libgl1-mesa-dri, libdrm2, libwayland-server0, libwayland-client0, libxkbcommon0, libpipewire-0.3-0t64 | libpipewire-0.3-0, pipewire, systemd, polkitd, pkexec, util-linux, e2fsprogs, iproute2, nftables, adb, libvulkan1, tar, zstd"
  RUNTIME_RECOMMENDS="wireplumber, mesa-vulkan-drivers, iptables"
  build_deb "droidloom-runtime" "$RUNTIME_DEPENDS" "$RUNTIME_RECOMMENDS"
fi

if (( BUILD_GAPPS )); then
  build_gapps_deb
fi

echo ""
echo "==> Done! Generated Debian packages in ${OUT_DIR}:"
ls -lh "${OUT_DIR}"/*.deb
