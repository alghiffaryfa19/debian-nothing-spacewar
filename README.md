# Debian Forky on Nothing Phone (1) (`spacewar`)

Single-boot (`userdata`) **Debian Forky (`arm64`)** image builder for Nothing Phone (1) (`spacewar`), featuring:

- **Kernel & Boot Image**: Mainline `sc7280-mainline` 7.2 kernel with the 41 Spacewar hardware patches and `spacewar-mkbootimg` (`Image.gz-dtb` + boot image header v2) referenced from `arch-nothing-spacewar`.
- **Single-Boot on `userdata`**: Flashes directly to `userdata` with `UUID`-based `/etc/fstab` and `x-systemd.growfs` to automatically expand the root filesystem on first boot.
- **Desktop Environment**: [Denial WM](https://denialwm.org) (`curl -fsSL https://install.denialwm.org | sh` + `sudo apt update && sudo apt install denial`) configured with `DENIAL_SHELL_PROFILE=mobile` and SDDM autologin.
- **Android Runtime & Google Apps**: [Droidloom](https://github.com/denialwm/droidloom) `aarch64` prebuilt packages (`droidloom-runtime`, `droidloom-image`, `droidloom-base`) with **LiteGapps (`LiteGapps-arm64-17.0-20261012-official.zip`)** verified and injected into `/usr/lib/droidloom/addons/gapps` via `droidloom-gapps`.

---

## 🛠️ Repository Layout

| Path | Description |
|---|---|
| `spacewar-kernel_build.sh` | Builds `linux-nothing-spacewar.deb`, `firmware-nothing-spacewar.deb`, and `alsa-nothing-spacewar.deb` with the Spacewar patch series (`kernel/patches/`). |
| `spacewar-rootfs_build.sh` | Builds the single-boot Debian `forky` rootfs (`spacewar-rootfs.img` & `spacewar-rootfs.sparse.img`) and `boot.img` with Denial WM, Droidloom, and LiteGapps. |
| `overlay/` | Spacewar hardware integration from `arch-nothing-spacewar`: `/usr/bin/spacewar-mkbootimg`, `/usr/share/nothing-spacewar/deviceinfo`, USB NCM gadget, DWC3 USB reprobe, LPASS VA macro audio reprobe, udev rules, and NetworkManager configs. |
| `kernel/` | Spacewar kernel config (`config-postmarketos-qcom-sc7280.aarch64`) and 41 hardware patches (`kernel/patches/`). |

---

## 🚀 Building Locally

### 1. Build Kernel & Device Packages (if not already downloaded from Releases)
```bash
chmod +x spacewar-kernel_build.sh
./spacewar-kernel_build.sh
```

### 2. Build Debian Forky RootFS & Boot Image
Ensure host tools are installed (`debootstrap`, `e2fsprogs`, `android-sdk-libsparse-utils`, `mkbootimg`, `libarchive-tools`, `zstd`, `xz-utils`, `erofs-utils >= 1.8`, `attr`, `fakeroot`, `aapt`, `apksigner`, `default-jre-headless`, and Rust `1.85+` / `1.93.0` via `rustup`), then run:

```bash
chmod +x spacewar-rootfs_build.sh
sudo bash ./spacewar-rootfs_build.sh
```

Outputs are written to `out/`:
- `out/boot.img`
- `out/spacewar-rootfs.img`
- `out/spacewar-rootfs.sparse.img`
- `out/packages.txt`
- `out/root.uuid`
- `out/SHA256SUMS`

---

## ⚡ Flashing (Single-Boot `userdata`)

> **Warning**: Back up your modem EFS partitions (`modemst1`, `modemst2`, `fsg`, `fsc`, `persist`) before flashing. Flashing `userdata` wipes existing Android user data.

```bash
fastboot flash boot_a out/boot.img
fastboot flash boot_b out/boot.img
fastboot flash userdata out/spacewar-rootfs.sparse.img
fastboot reboot
```

### Default Credentials & First Boot
- **Desktop User**: `user` / `147258` (SDDM autologin into Denial mobile session)
- **Root User**: `root` / `1234`
- **USB Networking**: Connect via USB; the phone exposes an NCM interface at `172.16.42.1` (`ssh user@172.16.42.1`).
- **Starting Droidloom (with pre-injected Google Apps)**:
  Inside the Denial Wayland session (as `user`, without `sudo`):
  ```bash
  droidloomctl start
  ```
  On first start, `droidloom-package-helper` automatically detects `/usr/lib/droidloom/addons/gapps` on fresh storage and activates Google Play Services & Play Store in `/etc/droidloom/cell.json`.
