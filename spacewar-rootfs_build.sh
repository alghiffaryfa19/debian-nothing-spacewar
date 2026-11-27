#!/bin/bash
set -euo pipefail

# ==============================================================================
# Nothing Phone (1) (spacewar) - Debian Forky Single-Boot (userdata) Builder
# Reference boot image & hardware integration: /home/fauzan/apps/arch-nothing-spacewar
# Desktop Environment: Denial WM (https://install.denialwm.org)
# Android Runtime: Droidloom aarch64 + LiteGapps (Android 17 / API 37)
# ==============================================================================

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DISTRO_SUITE="${DISTRO_SUITE:-forky}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian/}"
FILESYSTEM_UUID="${FILESYSTEM_UUID:-ee8d3593-59b1-480e-a3b6-4fefb17ee7d8}"
HOSTNAME="${HOSTNAME:-spacewar}"
USERNAME="${USERNAME:-user}"
USERPASS="${USERPASS:-147258}"
ROOTPASS="${ROOTPASS:-1234}"
ENABLE_DROIDLOOM="${ENABLE_DROIDLOOM:-true}"
ENABLE_GAPPS="${ENABLE_GAPPS:-true}"
SPLIT_ROOTFS="${SPLIT_ROOTFS:-false}"
SPLIT_SIZE="${SPLIT_SIZE:-1900M}"
LITEGAPPS_URL="${LITEGAPPS_URL:-https://sourceforge.net/projects/litegapps/files/litegapps/arm64/37/lite/2026-10-12/LiteGapps-arm64-17.0-20261012-official.zip/download}"
WORK_DIR="${WORK_DIR:-$REPO_DIR/.work}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_DIR/out}"

fail() {
    printf '❌ [spacewar-rootfs] Error: %s\n' "$*" >&2
    exit 1
}

if [[ "$(id -u)" -ne 0 ]]; then
    fail "Please run this script as root (sudo bash $0)"
fi

for tool in debootstrap curl gpg sha256sum mkfs.ext4 e2fsck blkid bsdtar zstd xz; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing required host tool: $tool"
done

mkdir -p "$WORK_DIR/cache" "$OUTPUT_DIR"
ROOTFS="$WORK_DIR/rootfs"

cleanup_mounts() {
    if [[ -d "$ROOTFS" ]]; then
        for mp in "$ROOTFS/dev/pts" "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/run"; do
            if mountpoint -q "$mp" 2>/dev/null; then
                umount -lf "$mp" 2>/dev/null || true
            fi
        done
    fi
}
trap cleanup_mounts EXIT

cleanup_mounts
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

echo "======================================================================"
echo "🚀 Building Debian ${DISTRO_SUITE} (arm64) Single-Boot (userdata)"
echo "   UUID       : ${FILESYSTEM_UUID}"
echo "   DE         : Denial WM"
echo "   Droidloom  : ${ENABLE_DROIDLOOM} (GApps: ${ENABLE_GAPPS})"
echo "   Output Dir : ${OUTPUT_DIR}"
echo "======================================================================"

# ==============================================================================
# 1. Bootstrap Debian Forky (arm64)
# ==============================================================================
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == "aarch64" ]]; then
    debootstrap --arch=arm64 --components=main,contrib,non-free,non-free-firmware \
        "$DISTRO_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"
else
    [[ -x /usr/bin/qemu-aarch64-static ]] || fail "Cross-building on $HOST_ARCH requires qemu-user-static (/usr/bin/qemu-aarch64-static)"
    debootstrap --arch=arm64 --foreign --components=main,contrib,non-free,non-free-firmware \
        "$DISTRO_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"
    install -Dm755 /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/qemu-aarch64-static"
    chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
fi

mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb ${DEBIAN_MIRROR} ${DISTRO_SUITE} main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR} ${DISTRO_SUITE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DISTRO_SUITE}-security main contrib non-free non-free-firmware
EOF

# Prevent service autostart inside chroot
cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

# ==============================================================================
# 2. Install Base System, Audio, Modem, and Droidloom Runtime Dependencies
# ==============================================================================
echo "📦 Installing base system, PipeWire, SDDM, and hardware support packages..."
chroot "$ROOTFS" apt-get update
DEBIAN_FRONTEND=noninteractive chroot "$ROOTFS" apt-get install -y \
    systemd systemd-sysv systemd-resolved udev dbus \
    sudo vim wget curl ca-certificates gnupg locales \
    network-manager openssh-server wpasupplicant \
    initramfs-tools kmod util-linux e2fsprogs parted \
    iproute2 nftables iptables \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber libspa-0.2-bluetooth \
    libpipewire-0.3-0t64 libwayland-server0 libgbm1 libxkbcommon0 libdrm2 \
    libgl1-mesa-dri libegl-mesa0 libvulkan1 mesa-vulkan-drivers mesa-utils-bin \
    firmware-qcom-soc firmware-atheros \
    polkitd pkexec \
    adb android-sdk-libsparse-utils mkbootimg \
    tar zstd xz-utils libarchive-tools erofs-utils attr fakeroot \
    alsa-ucm-conf bluez blueman power-profiles-daemon avahi-daemon \
    modemmanager libqmi-utils libmbim-utils qrtr-tools rmtfs tqftpserv \
    sddm qt6-wayland fcitx5 foot

# Compatibility symlink for Droidloom's /usr/bin/runuser calls on Debian
chroot "$ROOTFS" bash -c '
if [ ! -e /usr/bin/runuser ] && [ -x /usr/sbin/runuser ]; then
    ln -sf /usr/sbin/runuser /usr/bin/runuser
fi
'

# ==============================================================================
# 3. Install Nothing Phone (1) Custom .deb Packages & Overlay
# ==============================================================================
echo "📦 Installing Nothing Phone (1) device-specific .deb packages..."
mkdir -p "$ROOTFS/tmp/debs"
shopt -s nullglob
debs=("$REPO_DIR"/*.deb)
if (( ${#debs[@]} == 0 )); then
    fail "No device .deb packages found in $REPO_DIR (build or download kernel/device .deb packages first)"
fi
cp -v "${debs[@]}" "$ROOTFS/tmp/debs/"

DEBIAN_FRONTEND=noninteractive chroot "$ROOTFS" bash -c '
apt-get update
apt-get install -y /tmp/debs/*.deb || apt-get -f install -y
dpkg-divert --package soc-qcom --divert /etc/UPower/UPower.conf.distrib --no-rename --add /etc/UPower/UPower.conf
rm -rf /tmp/debs
'

echo "🔧 Applying Spacewar hardware overlay and boot tools (from arch-nothing-spacewar)..."
cp -a "$REPO_DIR/overlay/." "$ROOTFS/"
if [[ -f "$REPO_DIR/mkbootimg" ]]; then
    install -Dm755 "$REPO_DIR/mkbootimg" "$ROOTFS/usr/local/bin/mkbootimg"
fi
chmod 755 \
    "$ROOTFS/usr/bin/spacewar-mkbootimg" \
    "$ROOTFS/usr/bin/spacewar-usb-reprobe" \
    "$ROOTFS/usr/bin/spacewar-audio-reprobe" \
    "$ROOTFS/usr/local/libexec/spacewar-usb-gadget" \
    "$ROOTFS/etc/kernel/postinst.d/zz-spacewar-boot"

# Ensure pmOS firmware path is mapped to kernel's updates/ path
if [[ -d "$ROOTFS/lib/firmware/postmarketos" && ! -e "$ROOTFS/lib/firmware/updates" ]]; then
    mv "$ROOTFS/lib/firmware/postmarketos" "$ROOTFS/lib/firmware/updates"
fi

# Ensure rmtfs runs in read-only mode (-r) to protect modem EFS partitions
if [[ -f "$ROOTFS/usr/lib/systemd/system/rmtfs.service" ]]; then
    sed -i -E 's|^ExecStart=(.*/rmtfs)([[:space:]]+-P)?([[:space:]]+-s)?$|ExecStart=\1 -r -P -s|' \
        "$ROOTFS/usr/lib/systemd/system/rmtfs.service"
fi

# ==============================================================================
# 4. Install Denial Desktop Environment
# ==============================================================================
echo "🖥️ Setting up Denial repository and installing Denial WM..."
DENIAL_SIGNING_KEY="AE4108FA5E91E26BE0EE331E0F5B3AD16E023091"
DENIAL_KEY_URL="https://packages.denialwm.org/denial-repo-key.asc"

install -d -m 0755 "$ROOTFS/etc/apt/keyrings" "$ROOTFS/etc/apt/sources.list.d"
curl --proto '=https' --tlsv1.2 -fsSL "$DENIAL_KEY_URL" -o "$ROOTFS/etc/apt/keyrings/denial.asc"
chmod 0644 "$ROOTFS/etc/apt/keyrings/denial.asc"

actual_fpr=$(gpg --batch --show-keys --with-colons --fingerprint "$ROOTFS/etc/apt/keyrings/denial.asc" \
    | awk -F: '$1 == "fpr" { print toupper($10); exit }')
[[ "$actual_fpr" == "$DENIAL_SIGNING_KEY" ]] || fail "Denial signing key fingerprint mismatch: got $actual_fpr"

# Debian Forky uses the Denial trixie apt repository as defined by https://install.denialwm.org
cat > "$ROOTFS/etc/apt/sources.list.d/denial.sources" <<'EOF'
Types: deb
URIs: https://packages.denialwm.org/apt
Suites: trixie
Components: main
Architectures: arm64
Signed-By: /etc/apt/keyrings/denial.asc
EOF
chmod 0644 "$ROOTFS/etc/apt/sources.list.d/denial.sources"

# Run the official Denial installer script in a pseudo-terminal to verify configuration, then install denial
chroot "$ROOTFS" bash -c '
script -q -e -c "printf \"y\n\" | sh -c \"\$(curl -fsSL https://install.denialwm.org)\"" /dev/null || true
sudo apt update && sudo apt install -y denial
'

install -d -m 0755 "$ROOTFS/etc/denial"
cat > "$ROOTFS/etc/denial/session.conf" <<'EOF'
DENIAL_SHELL_PROFILE=mobile
export XMODIFIERS=@im=fcitx GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx
EOF
chmod 0644 "$ROOTFS/etc/denial/session.conf"

install -d -m 0755 "$ROOTFS/etc/environment.d"
cat > "$ROOTFS/etc/environment.d/70-spacewar-input-method.conf" <<'EOF'
XMODIFIERS=@im=fcitx
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
EOF

# ==============================================================================
# 5. Install Droidloom (aarch64 prebuilt binaries) & Inject LiteGapps
# ==============================================================================
if [[ "$ENABLE_DROIDLOOM" == "true" ]]; then
    echo "🤖 Installing Droidloom aarch64 packages into Debian Forky rootfs..."
    DL_VER_JSON=$(curl -fsSL https://raw.githubusercontent.com/denialwm/droidloom/refs/heads/main/packaging/arch/version.json)
    DL_VERSION=$(awk -F'"' '/"version"/ {print $4}' <<<"$DL_VER_JSON")
    DL_RELEASE=$(awk -F'[:, ]+' '/"release"/ {print $3}' <<<"$DL_VER_JSON")
    DL_FULL_VER="${DL_VERSION}-${DL_RELEASE}"

    DL_BASE_JSON=$(curl -fsSL https://denialwm.github.io/droidloom/aarch64/base.json)
    DL_BASE_VER=$(awk -F'"' '/"version"/ {print $4}' <<<"$DL_BASE_JSON")

    [[ -n "$DL_FULL_VER" && -n "$DL_BASE_VER" ]] || fail "Could not resolve Droidloom version metadata"
    echo "   Droidloom Runtime/Image : ${DL_FULL_VER}"
    echo "   Droidloom Base          : ${DL_BASE_VER}"

    DL_RELEASE_URL="https://github.com/denialwm/droidloom/releases/download/packages"
    for pkg_archive in \
        "droidloom-base-${DL_BASE_VER}-aarch64.pkg.tar.zst" \
        "droidloom-image-${DL_FULL_VER}-aarch64.pkg.tar.zst" \
        "droidloom-runtime-${DL_FULL_VER}-aarch64.pkg.tar.zst"; do
        cache_path="$WORK_DIR/cache/$pkg_archive"
        if [[ ! -s "$cache_path" ]]; then
            echo "⬇️ Downloading $pkg_archive..."
            curl -fL --retry 3 -o "$cache_path.partial" "$DL_RELEASE_URL/$pkg_archive"
            mv -f "$cache_path.partial" "$cache_path"
        fi
        echo "📦 Extracting $pkg_archive into rootfs..."
        bsdtar --acls --xattrs --numeric-owner -xpf "$cache_path" -C "$ROOTFS" \
            --exclude='.PKGINFO' --exclude='.BUILDINFO' --exclude='.MTREE' --exclude='.INSTALL'
    done

    # Remove Arch libalpm hooks (not needed on Debian)
    rm -rf "$ROOTFS/usr/share/libalpm"

    if [[ "$ENABLE_GAPPS" == "true" ]]; then
        echo "🧩 Building and injecting LiteGapps add-on via droidloom-gapps..."
        if [[ -n "${SUDO_USER:-}" && -d "/home/${SUDO_USER}/.cargo/bin" ]]; then
            export PATH="/home/${SUDO_USER}/.cargo/bin:$PATH"
        fi
        if [[ -d "/root/.cargo/bin" ]]; then
            export PATH="/root/.cargo/bin:$PATH"
        fi
        command -v cargo >/dev/null 2>&1 || fail "Missing host tool: cargo (install rustup or cargo)"

        GAPPS_ZIP="$WORK_DIR/cache/LiteGapps-arm64-17.0-20261012-official.zip"
        if [[ ! -s "$GAPPS_ZIP" ]]; then
            echo "⬇️ Downloading LiteGapps archive..."
            curl -fL --retry 3 -o "$GAPPS_ZIP.partial" "$LITEGAPPS_URL"
            mv -f "$GAPPS_ZIP.partial" "$GAPPS_ZIP"
        fi
        GAPPS_SHA256=$(sha256sum "$GAPPS_ZIP" | awk '{print $1}')
        echo "   LiteGapps SHA-256: $GAPPS_SHA256"

        DL_SRC_TAR="$WORK_DIR/cache/droidloom-source-${DL_FULL_VER}.tar.gz"
        if [[ ! -s "$DL_SRC_TAR" ]]; then
            echo "⬇️ Downloading droidloom-source-${DL_FULL_VER}.tar.gz..."
            curl -fL --retry 3 -o "$DL_SRC_TAR.partial" "$DL_RELEASE_URL/droidloom-source-${DL_FULL_VER}.tar.gz"
            mv -f "$DL_SRC_TAR.partial" "$DL_SRC_TAR"
        fi

        rm -rf "$WORK_DIR/droidloom-src" "$WORK_DIR/gapps-arm64"
        mkdir -p "$WORK_DIR/droidloom-src"
        tar -xzf "$DL_SRC_TAR" -C "$WORK_DIR/droidloom-src"
        DL_SRC_DIR="$WORK_DIR/droidloom-src/droidloom"

        echo "🔨 Compiling droidloom-gapps tool..."
        (
            cd "$DL_SRC_DIR"
            cargo build --locked -j 1 -p droidloom-gapps
        )
        GAPPS_BIN="$DL_SRC_DIR/target/debug/droidloom-gapps"
        [[ -x "$GAPPS_BIN" ]] || fail "Failed to build droidloom-gapps binary"

        # Prefer running on host if erofs-utils >= 1.8 (--mkfs-time) and aapt2/apksigner exist;
        # otherwise run inside the Debian Forky chroot which has erofs-utils 1.8+.
        if command -v aapt2 >/dev/null 2>&1 && command -v apksigner >/dev/null 2>&1 \
            && command -v mkfs.erofs >/dev/null 2>&1 && mkfs.erofs --help 2>&1 | grep -q -- '--mkfs-time'; then
            echo "🔍 Running droidloom-gapps on host..."
            "$GAPPS_BIN" inspect "$GAPPS_ZIP"
            "$GAPPS_BIN" build \
                --archive "$GAPPS_ZIP" \
                --sha256 "$GAPPS_SHA256" \
                --base "$ROOTFS/usr/lib/droidloom/images" \
                --output "$WORK_DIR/gapps-arm64" \
                --aapt2 "$(command -v aapt2)" \
                --apksigner "$(command -v apksigner)"
            "$GAPPS_BIN" verify \
                --addon "$WORK_DIR/gapps-arm64" \
                --base "$ROOTFS/usr/lib/droidloom/images"
        elif [[ "$HOST_ARCH" == "aarch64" ]]; then
            echo "🔍 Running droidloom-gapps inside Debian Forky chroot (erofs-utils 1.8+)..."
            DEBIAN_FRONTEND=noninteractive chroot "$ROOTFS" apt-get install -y aapt apksigner
            install -Dm755 "$GAPPS_BIN" "$ROOTFS/tmp/droidloom-gapps"
            cp -f "$GAPPS_ZIP" "$ROOTFS/tmp/LiteGapps.zip"
            rm -rf "$ROOTFS/tmp/gapps-arm64"
            chroot "$ROOTFS" /tmp/droidloom-gapps inspect /tmp/LiteGapps.zip
            chroot "$ROOTFS" /tmp/droidloom-gapps build \
                --archive /tmp/LiteGapps.zip \
                --sha256 "$GAPPS_SHA256" \
                --base /usr/lib/droidloom/images \
                --output /tmp/gapps-arm64 \
                --aapt2 /usr/bin/aapt2 \
                --apksigner /usr/bin/apksigner
            chroot "$ROOTFS" /tmp/droidloom-gapps verify \
                --addon /tmp/gapps-arm64 \
                --base /usr/lib/droidloom/images
            mv "$ROOTFS/tmp/gapps-arm64" "$WORK_DIR/gapps-arm64"
            rm -f "$ROOTFS/tmp/droidloom-gapps" "$ROOTFS/tmp/LiteGapps.zip"
            DEBIAN_FRONTEND=noninteractive chroot "$ROOTFS" apt-get purge -y --auto-remove aapt apksigner
        else
            fail "Host is missing aapt2, apksigner, or erofs-utils >= 1.8 (--mkfs-time)"
        fi

        # Install verified GApps add-on directly to /usr/lib/droidloom/addons/gapps
        # Note: droidloom-package-helper automatically selects /usr/lib/droidloom/addons/gapps on first setup!
        GAPPS_DEST="$ROOTFS/usr/lib/droidloom/addons/gapps"
        rm -rf "$GAPPS_DEST"
        install -d -m 0755 -o 0 -g 0 "$GAPPS_DEST/images" "$ROOTFS/usr/share/licenses/droidloom-gapps"
        for item in manifest.json import-report.json LICENSE.LiteGapps NOTICE images/product.img images/system_ext.img; do
            cp --reflink=auto --sparse=always -- "$WORK_DIR/gapps-arm64/$item" "$GAPPS_DEST/$item"
        done
        cp -- "$WORK_DIR/gapps-arm64/LICENSE.LiteGapps" "$ROOTFS/usr/share/licenses/droidloom-gapps/LICENSE.LiteGapps"
        cp -- "$WORK_DIR/gapps-arm64/NOTICE" "$ROOTFS/usr/share/licenses/droidloom-gapps/NOTICE"
        chown -R 0:0 "$ROOTFS/usr/lib/droidloom" "$ROOTFS/usr/share/licenses/droidloom-gapps"
        chmod -R u=rwX,go=rX "$GAPPS_DEST"
        rm -rf "$WORK_DIR/gapps-arm64" "$WORK_DIR/droidloom-src"
        echo "✅ LiteGapps successfully verified and injected into /usr/lib/droidloom/addons/gapps"
    fi
fi

# ==============================================================================
# 6. Users, Locale, SDDM Autologin, Fstab (userdata single-boot), and Services
# ==============================================================================
echo "⚙️ Configuring system users, SDDM autologin, services, and single-boot fstab..."
printf '%s\n' "$HOSTNAME" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
EOF

# Single-boot userdata fstab & kernel cmdline (referencing arch-nothing-spacewar)
install -d -m 0755 "$ROOTFS/etc/kernel"
printf 'console=ttyMSM0,115200 earlycon loglevel=7 root=UUID=%s rw rootwait\n' "$FILESYSTEM_UUID" > "$ROOTFS/etc/kernel/cmdline"
printf 'UUID=%s / ext4 defaults,x-systemd.growfs 0 1\n' "$FILESYSTEM_UUID" > "$ROOTFS/etc/fstab"
chmod 0644 "$ROOTFS/etc/kernel/cmdline" "$ROOTFS/etc/fstab"

# SDDM autologin into Denial session (no physical keyboard on phone boot)
install -d -m 0755 "$ROOTFS/etc/sddm.conf.d"
cat > "$ROOTFS/etc/sddm.conf.d/zz-spacewar-autologin.conf" <<EOF
[Autologin]
User=${USERNAME}
Session=denial.desktop
Relogin=true
EOF
chmod 0644 "$ROOTFS/etc/sddm.conf.d/zz-spacewar-autologin.conf"

chroot "$ROOTFS" /bin/bash -euxc "
echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

echo 'root:${ROOTPASS}' | chpasswd
if ! getent passwd '${USERNAME}' >/dev/null; then
    useradd -m -s /bin/bash '${USERNAME}'
fi
echo '${USERNAME}:${USERPASS}' | chpasswd
for grp in sudo video render audio plugdev bluetooth netdev input; do
    if getent group \"\$grp\" >/dev/null; then
        usermod -aG \"\$grp\" '${USERNAME}'
    fi
done

systemctl enable ssh NetworkManager systemd-networkd systemd-resolved sddm
systemctl enable bluetooth power-profiles-daemon avahi-daemon
systemctl enable spacewar-usb-reprobe.service spacewar-usb-gadget.service spacewar-audio-reprobe.service
systemctl enable rmtfs tqftpserv ModemManager pd-mapper || true
if systemctl list-unit-files | grep -q '^msm-modem-uim-selection'; then
    systemctl enable msm-modem-uim-selection.service
fi
systemctl disable q6voiced.service 2>/dev/null || true
systemctl mask systemd-firstboot.service
systemctl set-default graphical.target

# Remove slow wpa_supplicant template units
rm -f /lib/systemd/system/wpa_supplicant@.service \
      /lib/systemd/system/wpa_supplicant-wired@.service \
      /lib/systemd/system/wpa_supplicant-nl80211@.service
"

# ==============================================================================
# 7. Build Initramfs and Boot Image (spacewar-mkbootimg)
# ==============================================================================
echo "🛠️ Generating initramfs and building boot.img (arch-nothing-spacewar method)..."
install -d -m 0755 "$ROOTFS/etc/initramfs-tools"
cat >> "$ROOTFS/etc/initramfs-tools/modules" <<'EOF'
fsa4480
msm
panel-visionox-rm692e5
spi-geni-qcom
fts_tp
ufs_qcom
ufshcd_core
ufshcd_pltfrm
phy_qcom_qmp_ufs
ext4
EOF

chroot "$ROOTFS" /usr/bin/spacewar-mkbootimg --rebuild-initramfs
[[ -s "$ROOTFS/boot/boot.img" ]] || fail "spacewar-mkbootimg did not produce /boot/boot.img"
cp -f "$ROOTFS/boot/boot.img" "$OUTPUT_DIR/boot.img"

# Save package manifest
chroot "$ROOTFS" dpkg-query -W -f='${Package} ${Version}\n' > "$OUTPUT_DIR/packages.txt"
printf '%s\n' "$FILESYSTEM_UUID" > "$OUTPUT_DIR/root.uuid"

# Clean up chroot temporary files
rm -f "$ROOTFS/usr/sbin/policy-rc.d"
chroot "$ROOTFS" apt-get clean
rm -rf "$ROOTFS/var/lib/apt/lists/"* "$ROOTFS/tmp/"* "$ROOTFS/var/tmp/"*
rm -f "$ROOTFS/etc/ssh/ssh_host_"* "$ROOTFS/var/lib/systemd/random-seed" "$ROOTFS/var/lib/dbus/machine-id"
: > "$ROOTFS/etc/machine-id"

cleanup_mounts
if [[ "$HOST_ARCH" != "aarch64" ]]; then
    rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
fi
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"

# ==============================================================================
# 8. Assemble RootFS ext4 & Android Sparse Image for userdata
# ==============================================================================
used_mib=$(du --apparent-size -sm "$ROOTFS" | cut -f1)
size_mib=$((used_mib + used_mib / 4 + 2048))
(( size_mib >= 10240 )) || size_mib=10240
echo "💽 Rootfs apparent size: ${used_mib} MiB -> Creating ext4 image: ${size_mib} MiB..."

RAW_IMG="$OUTPUT_DIR/spacewar-rootfs.img"
SPARSE_IMG="$OUTPUT_DIR/spacewar-rootfs.sparse.img"
rm -f "$RAW_IMG" "$SPARSE_IMG"

truncate -s "${size_mib}M" "$RAW_IMG"
mkfs.ext4 -F -U "$FILESYSTEM_UUID" -L spacewar-root -m 0 -d "$ROOTFS" "$RAW_IMG"
e2fsck -fn "$RAW_IMG"
[[ "$(blkid -p -s UUID -o value "$RAW_IMG")" == "$FILESYSTEM_UUID" ]] || fail "Rootfs image UUID mismatch"

if command -v img2simg >/dev/null 2>&1; then
    echo "🗜️ Converting raw ext4 image to Android sparse image for fastboot flash userdata..."
    img2simg "$RAW_IMG" "$SPARSE_IMG"
fi

(
    cd "$OUTPUT_DIR"
    artifacts=(boot.img spacewar-rootfs.img packages.txt root.uuid)
    [[ ! -f spacewar-rootfs.sparse.img ]] || artifacts+=(spacewar-rootfs.sparse.img)
    sha256sum "${artifacts[@]}" > SHA256SUMS
    cat SHA256SUMS

    if [[ "$SPLIT_ROOTFS" == "true" ]]; then
        target_img="spacewar-rootfs.sparse.img"
        [[ -f "$target_img" ]] || target_img="spacewar-rootfs.img"
        echo "🗜️ Compressing and splitting ${target_img} (part size: ${SPLIT_SIZE})..."
        rm -f "${target_img}.zst" "${target_img}.zst.part"*
        zstd -T0 -19 --rm "$target_img" -o "${target_img}.zst"
        rm -f spacewar-rootfs.img
        split -b "$SPLIT_SIZE" -d -a 2 "${target_img}.zst" "${target_img}.zst.part"
        rm -f "${target_img}.zst"
        sha256sum boot.img "${target_img}.zst.part"* packages.txt root.uuid > SHA256SUMS.zst
        cat SHA256SUMS.zst
    fi
)

echo "======================================================================"
echo "✅ BUILD COMPLETE!"
echo "   Boot Image   : $OUTPUT_DIR/boot.img"
echo "   RootFS (raw) : $OUTPUT_DIR/spacewar-rootfs.img"
[[ -f "$SPARSE_IMG" ]] && echo "   RootFS (sparse): $SPARSE_IMG"
echo ""
echo "⚡ Fastboot single-boot flashing commands:"
echo "   fastboot flash boot_a $OUTPUT_DIR/boot.img"
echo "   fastboot flash boot_b $OUTPUT_DIR/boot.img"
echo "   fastboot flash userdata ${SPARSE_IMG:-$RAW_IMG}"
echo "   fastboot reboot"
echo "======================================================================"
