#!/bin/bash
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KERNEL_COMMIT="${KERNEL_COMMIT:-b90de19446e8bdaf222380b5a1d230c006d2912a}"
ARCH="arm64"

if [[ -z "${CCACHE_DIR:-}" ]]; then
    export CCACHE_DIR="${HOME}/.ccache"
    export CCACHE_MAXSIZE="10G"
    export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
fi
mkdir -p "$CCACHE_DIR"

export CC="ccache clang"
export CXX="ccache clang++"
export AR="llvm-ar"
export NM="llvm-nm"
export OBJCOPY="llvm-objcopy"
export OBJDUMP="llvm-objdump"
export READELF="llvm-readelf"
export STRIP="llvm-strip"

cd "$REPO_DIR"
rm -rf linux
mkdir -p linux
echo "⬇️ Fetching sc7280-mainline/linux (${KERNEL_COMMIT})..."
curl -fL --retry 3 "https://github.com/sc7280-mainline/linux/archive/${KERNEL_COMMIT}.tar.gz" \
    | tar -xz --strip-components=1 -C linux

cd linux

echo "🩹 Applying Spacewar kernel patches (from arch-nothing-spacewar)..."
if [[ -d "$REPO_DIR/kernel/patches" ]]; then
    for patch_file in "$REPO_DIR"/kernel/patches/*.patch; do
        [[ -f "$patch_file" ]] || continue
        echo "  -> $(basename "$patch_file")"
        patch -Np1 -i "$patch_file"
    done
fi

if [[ -f "$REPO_DIR/kernel/config-postmarketos-qcom-sc7280.aarch64" ]]; then
    cp "$REPO_DIR/kernel/config-postmarketos-qcom-sc7280.aarch64" .config
else
    wget https://gitlab.postmarketos.org/postmarketOS/pmaports/-/raw/main/device/community/linux-postmarketos-qcom-sc7280/config-postmarketos-qcom-sc7280.aarch64 -O .config
fi

scripts/config --disable LOCALVERSION_AUTO --set-str LOCALVERSION "-sc7280"
make -j"$(nproc)" ARCH="$ARCH" LLVM=1 olddefconfig
make -j"$(nproc)" ARCH="$ARCH" LLVM=1 Image Image.gz vmlinuz.efi modules dtbs

_kernel_version="$(make ARCH="$ARCH" LLVM=1 kernelrelease -s)"
echo "✅ Built kernel release: ${_kernel_version}"

PKGDIR="$REPO_DIR/linux-nothing-spacewar"
rm -rf "$PKGDIR/boot" "$PKGDIR/lib" "$PKGDIR/usr"
mkdir -p "$PKGDIR/boot"

sed -i "s/^Version:.*/Version: ${_kernel_version}/" "$PKGDIR/DEBIAN/control"

# =========================
# Install kernel images
# =========================
install -Dm644 "arch/$ARCH/boot/Image"       "$PKGDIR/boot/Image"
install -Dm644 "arch/$ARCH/boot/Image.gz"    "$PKGDIR/boot/Image.gz"
install -Dm644 "arch/$ARCH/boot/vmlinuz"     "$PKGDIR/boot/vmlinuz"
install -Dm644 "arch/$ARCH/boot/vmlinuz.efi" "$PKGDIR/boot/linux.efi"
install -Dm644 .config                       "$PKGDIR/boot/config-${_kernel_version}"
install -Dm644 System.map                    "$PKGDIR/boot/System.map-${_kernel_version}"

# =========================
# Install modules + dtbs
# =========================
make -j"$(nproc)" \
    ARCH="$ARCH" \
    LLVM=1 \
    INSTALL_PATH="$PKGDIR/boot" \
    INSTALL_MOD_PATH="$PKGDIR" \
    INSTALL_MOD_STRIP=1 \
    INSTALL_DTBS_PATH="$PKGDIR/boot/dtbs" \
    modules_install dtbs_install

depmod -a -b "$PKGDIR" "$_kernel_version"

# =========================
# Cleanup & metadata
# =========================
rm -rf "$PKGDIR"/lib/modules/*/{build,source} 2>/dev/null || true

mkdir -p "$PKGDIR/usr/share/kernel/spacewar"
printf '%s\n' "$_kernel_version" > "$PKGDIR/usr/share/kernel/spacewar/kernel.release"

cd "$REPO_DIR"

# =========================
# Package firmware & ALSA UCM
# =========================
rm -rf firmware "$REPO_DIR/firmware-nothing-spacewar/lib" "$REPO_DIR/firmware-nothing-spacewar/usr"
git clone --depth 1 https://github.com/mainlining/firmware-nothing-spacewar firmware
if [[ -d firmware/usr ]]; then
    cp -a firmware/usr "$REPO_DIR/firmware-nothing-spacewar/"
fi
if [[ -d firmware/lib/firmware ]]; then
    mkdir -p "$REPO_DIR/firmware-nothing-spacewar/lib"
    cp -a firmware/lib/firmware "$REPO_DIR/firmware-nothing-spacewar/lib/"
    if [[ -d "$REPO_DIR/firmware-nothing-spacewar/lib/firmware/postmarketos" ]]; then
        mv "$REPO_DIR/firmware-nothing-spacewar/lib/firmware/postmarketos" \
           "$REPO_DIR/firmware-nothing-spacewar/lib/firmware/updates"
    fi
fi
rm -rf firmware

dpkg-deb --build --root-owner-group linux-nothing-spacewar
dpkg-deb --build --root-owner-group firmware-nothing-spacewar
dpkg-deb --build --root-owner-group alsa-nothing-spacewar
echo "✅ Built packages: linux-nothing-spacewar.deb, firmware-nothing-spacewar.deb, alsa-nothing-spacewar.deb"
