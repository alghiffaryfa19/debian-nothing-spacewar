# 仅在未设置环境变量时配置ccache
if [ -z "$CCACHE_DIR" ]; then
    export CCACHE_DIR="/home/runner/.ccache"
    export CCACHE_MAXSIZE="10G"
    export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
fi

# 确保ccache目录存在
mkdir -p "$CCACHE_DIR"

# 确保ccache优先使用clang
export CC="ccache clang"
export CXX="ccache clang++"
export AR="llvm-ar"
export NM="llvm-nm"
export OBJCOPY="llvm-objcopy"
export OBJDUMP="llvm-objdump"
export READELF="llvm-readelf"
export STRIP="llvm-strip"

git clone https://github.com/sc7280-mainline/linux.git --depth 1 linux
cd linux

wget https://gitlab.postmarketos.org/postmarketOS/pmaports/-/raw/main/device/community/linux-postmarketos-qcom-sc7280/config-postmarketos-qcom-sc7280.aarch64 -O .config

make -j$(nproc) ARCH=arm64 LLVM=1
make -j$(nproc) ARCH=arm64 LLVM=1 dtbs

_kernel_version="$(make kernelrelease -s)"


sed -i "s/Version:.*/Version: ${_kernel_version}/" ../linux-nothing-spacewar/DEBIAN/control

#rm $1/linux-nothing-spacewar/usr/dummy

PKGDIR=../linux-nothing-spacewar
ARCH=arm64

# =========================
# Install kernel images
# =========================
mkdir -p $PKGDIR/boot

install -Dm644 arch/$ARCH/boot/vmlinuz.efi \
    $PKGDIR/boot/linux.efi

install -Dm644 arch/$ARCH/boot/vmlinuz \
    $PKGDIR/boot/vmlinuz

install -Dm644 .config \
    $PKGDIR/boot/config-${_kernel_version}

install -Dm644 System.map \
    $PKGDIR/boot/System.map-${_kernel_version}

# =========================
# Install modules + dtbs
# =========================
make -j$(nproc) \
    ARCH=$ARCH \
    LLVM=1 \
    INSTALL_PATH=$PKGDIR/boot \
    INSTALL_MOD_PATH=$PKGDIR \
    INSTALL_MOD_STRIP=1 \
    INSTALL_DTBS_PATH=$PKGDIR/boot/dtbs \
    modules_install dtbs_install

depmod -a -b $PKGDIR $_kernel_version

# =========================
# Cleanup
# =========================
rm -rf $PKGDIR/lib/modules/*/{build,source} 2>/dev/null || true

# =========================
# Save kernel version info
# =========================
mkdir -p $PKGDIR/usr/share/kernel/spacewar
cp include/config/kernel.release \
   $PKGDIR/usr/share/kernel/spacewar/kernel.release

cd ..

dpkg-deb --build --root-owner-group linux-nothing-spacewar
dpkg-deb --build --root-owner-group firmware-nothing-spacewar
dpkg-deb --build --root-owner-group alsa-nothing-spacewar
