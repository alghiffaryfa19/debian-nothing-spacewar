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

make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1
_kernel_version="$(make kernelrelease -s)"


sed -i "s/Version:.*/Version: ${_kernel_version}/" ../linux-nothing-spacewar/DEBIAN/control

chmod +x ../mkbootimg

cat arch/arm64/boot/Image arch/arm64/boot/dts/qcom/sm7325-nothing-spacewar.dtb > Image-dtb_spacewar
mv Image-dtb_spacewar zImage_spacewar
../mkbootimg --kernel zImage_spacewar --cmdline "root=PARTLABEL=linux" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_spacewar_dualboot.img
../mkbootimg --kernel zImage_spacewar --cmdline "root=PARTLABEL=userdata" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_spacewar_singleboot.img

#rm $1/linux-nothing-spacewar/usr/dummy

make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 INSTALL_MOD_PATH=../linux-nothing-spacewar modules_install
rm ../linux-nothing-spacewar/lib/modules/**/build

cd ..

dpkg-deb --build --root-owner-group linux-nothing-spacewar
dpkg-deb --build --root-owner-group firmware-nothing-spacewar
dpkg-deb --build --root-owner-group alsa-nothing-spacewar
