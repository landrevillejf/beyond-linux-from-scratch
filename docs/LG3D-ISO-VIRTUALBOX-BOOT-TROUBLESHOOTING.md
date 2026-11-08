# LG3D Live ISO - VirtualBox Boot Troubleshooting Guide

## Problem Summary

The LG3D live ISOs produced by `lg3d.yml` (both systemd and sysvinit variants) are **BIOS-only bootable images**. They **cannot boot in UEFI mode** because the EFI bootloader (`/EFI/BOOT/BOOTX64.EFI`) is not present in the ISO.

**Root Cause:** The build process installs GRUB for BIOS (`i386-pc` target) but does not install the UEFI GRUB package (`grub-efi-amd64` or `shim-signed`), so `final/15-create-live-system.sh` detects the missing EFI file and falls back to BIOS-only ISO creation.

---

## ISO Inspection Results

### File: `lfs-0.57.4-lg3d-x86_64-systemd-20261103.iso`

```
Type: ISO 9660 CD-ROM filesystem data (DOS/MBR boot sector)
Volume ID: LFS_LIVE
Bootable: Yes (El Torito, BIOS only)
Size: 1.38 GiB

Contents:
/
├── EFI/
│   └── BOOT/          (EMPTY - no BOOTX64.EFI)
├── boot/
│   └── grub/          (empty directory)
├── isolinux/
│   ├── boot.cat
│   ├── initrd.img     (8.0 MB)
│   ├── isolinux.bin   (38 KB)
│   ├── isolinux.cfg
│   └── vmlinuz        (7.8 MB)
└── live.squashfs      (1.47 GB)
```

**Boot Configuration (isolinux.cfg):**
```
default live
label live
  kernel vmlinuz
  append initrd=initrd.img root=/dev/sr0 ro quiet
label live-verbose
  kernel vmlinuz
  append initrd=initrd.img root=/dev/sr0 ro
```

**Partition Table:**
```
Disklabel type: dos (MBR)
Device: *.iso1 *        0 2896415 2896416  1.4G 17 Hidden
Boot flag: Yes (on partition 1)
```

---

## Solution 1: Boot in BIOS Mode (VirtualBox)

VirtualBox 7.x defaults to UEFI mode for new virtual machines. You must **switch to BIOS mode** to boot these ISOs.

### Step-by-Step Instructions

#### For a New Virtual Machine:

1. **Open VirtualBox Manager**
2. **Click "New"** to create a VM
3. **Name and Operating System:**
   - Name: `LG3D Live` (or any name you prefer)
   - Type: `Linux`
   - Version: `Other Linux (64-bit)`
   - Click **Next**

4. **Hardware Settings:**
   - Base Memory: `2048 MB` or more (LG3D is a Java-based desktop)
   - Processors: `2` or more
   - Click **Next**

5. **Hard Disk:**
   - Select **"Do not add a virtual hard disk"** (live ISO doesn't need it)
   - Click **Create**

6. **Configure BIOS Mode (CRITICAL STEP):**
   - Select the newly created VM in the left pane
   - Click **"Settings"** (gear icon)
   - Go to **"System"** → **"Motherboard"** tab
   - **Uncheck** ☐ **"Enable EFI (special OSes only)"**
   - This forces the VM to use **BIOS/CSM** boot mode
   - Click **OK**

7. **Attach the ISO:**
   - In VM Settings, go to **"Storage"**
   - Under **"Controller: IDE"**, click the **empty disk icon**
   - Click the **disk icon** on the right → **"Choose a disk file..."**
   - Browse and select: `lfs-0.57.4-lg3d-x86_64-systemd-20261103.iso` (or sysvinit variant)
   - Click **OK**

8. **Configure Boot Order:**
   - Go to **"System"** → **"Motherboard"** tab
   - In **"Boot Order"**, ensure **"Optical"** is checked and moved to the top
   - Use the up/down arrows to prioritize: `Optical → Hard Disk → Network`
   - Click **OK**

9. **Start the VM:**
   - Click **"Start"**
   - You should see the **ISOLINUX boot menu** with options:
     - `live` (default, quiet boot)
     - `live-verbose` (shows boot messages)
   - Press **Enter** to boot the live system

### Expected Boot Sequence (BIOS Mode)

```
ISOLINUX 6.04 ...
[boot menu appears]
Loading vmlinuz...
Loading initrd.img...
[  0.000000] Linux version 6.x.x ...
...
[    5.123456] VFS: Mounted root (squashfs filesystem) readonly
...
[   12.345678] INIT: version 3.x booting
...
Welcome to Way Beyond Linux From Scratch (LG3D)
live@lg3d-live:~$
```

---

## Solution 2: Use VirtualBox 6.1 (Legacy BIOS Default)

If you have VirtualBox 6.1 installed, it defaults to BIOS mode for Linux VMs, so the ISO should boot without configuration changes.

**Note:** VirtualBox 6.1 is end-of-life. Prefer Solution 1 with VirtualBox 7.x.

---

## Solution 3: Boot on Real Hardware (BIOS Mode)

Most modern UEFI firmware supports **CSM (Compatibility Support Module)** or **Legacy BIOS boot**.

### Instructions:

1. **Create a bootable USB drive:**
   ```bash
   # On Linux/macOS
   sudo dd if=lfs-0.57.4-lg3d-x86_64-systemd-20261103.iso of=/dev/sdX bs=4M status=progress
   sync
   
   # Replace /dev/sdX with your USB device (NOT a partition like /dev/sda1)
   ```

2. **Configure firmware to use BIOS/CSM:**
   - Reboot and enter firmware setup (usually `F2`, `F10`, `Del`, or `Esc`)
   - Navigate to **Boot** or **Advanced** settings
   - Find **"Boot Mode"** or **"UEFI/Legacy Boot"**
   - Change from **"UEFI"** to **"Legacy"** or **"CSM"** or **"BIOS"**
   - Disable **Secure Boot** (optional, but recommended for troubleshooting)
   - Save and exit

3. **Boot from USB:**
   - Reboot and enter boot menu (usually `F12`, `F8`, or `F10`)
   - Select the USB drive (it should show as "USB HDD" or similar, NOT "UEFI: USB Device")
   - The ISOLINUX boot menu should appear

---

## Advanced: Fix the ISO to Support UEFI

If you need UEFI boot support, you must rebuild the ISO with the EFI bootloader included.

### Required Changes to Build Process

The issue is in `final/13-create-bootloader.sh` and the package list. The build must install `grub-efi-amd64` or `shim-signed` to generate `/boot/efi/EFI/BOOT/BOOTX64.EFI`.

#### Option A: Install GRUB EFI Package

Add to the BLFS stage that builds GRUB (likely `blfs/08-build-blfs-base.sh` or similar):

```bash
# Inside the LFS chroot
cd /sources/grub-2.12
./configure --prefix=/usr \
            --sbindir=/usr/sbin \
            --mandir=/usr/share/man \
            --infodir=/usr/share/info \
            --build=x86_64-linux-gnu \
            --host=x86_64-linux-gnu \
            --with-platform=efi \
            --disable-efiemu
make
make install

# Install EFI binaries to the standard location
grub-install --target=x86_64-efi \
             --efi-directory=/boot/efi \
             --bootloader-id=GRUB \
             --removable
```

#### Option B: Use shim-signed for Secure Boot

For Secure Boot support, install `shim` and `grub-efi`:

```bash
# Download and install shim
cd /sources
wget https://github.com/rhboot/shim/releases/download/15.8/shim-15.8.tar.bz2
tar xf shim-15.8.tar.bz2
cd shim-15.8
make DESTDIR=/boot/efi install

# Copy shim as the default EFI bootloader
cp /boot/efi/EFI/GRUB/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
cp /boot/efi/EFI/GRUB/mmx64.efi /boot/efi/EFI/BOOT/
```

#### Rebuild the ISO

After installing the EFI bootloader, re-run `final/15-create-live-system.sh`:

```bash
# The script will now detect /boot/efi/EFI/BOOT/BOOTX64.EFI
# and include UEFI boot support in the ISO
bash final/15-create-live-system.sh
```

The resulting ISO will have:
- **BIOS boot** via ISOLINUX (for legacy/CSM mode)
- **UEFI boot** via GRUB/shim (for native UEFI mode)
- **Hybrid MBR/GPT** partition table

---

## Troubleshooting

### Issue: "No bootable medium found" in VirtualBox

**Cause:** VM is configured for UEFI mode, but ISO is BIOS-only.

**Fix:** Disable EFI in VM settings (see Solution 1, step 6).

### Issue: ISOLINUX boot menu appears, but kernel panics

**Symptoms:**
```
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

**Cause:** The `root=/dev/sr0` parameter in `isolinux.cfg` may not match the actual CD-ROM device in the VM.

**Fix:** Edit the boot command at the ISOLINUX menu:
1. At the `boot:` prompt, type: `live-verbose`
2. Press **Tab** to edit the command line
3. Change `root=/dev/sr0` to `root=/dev/sr1` or `root=/dev/sda`
4. Press **Enter** to boot

### Issue: Boot hangs at "Loading initial ramdisk..."

**Cause:** Insufficient RAM allocated to the VM.

**Fix:** Increase VM memory to at least **2048 MB** (preferably **4096 MB** for LG3D).

### Issue: Screen goes black after ISOLINUX menu

**Cause:** Graphics mode incompatibility with VirtualBox VGA emulation.

**Fix:** Add `nomodeset` to the kernel command line:
1. At the `boot:` prompt, type: `live nomodeset`
2. Press **Enter**

---

## File Comparison: systemd vs sysvinit ISOs

Both ISOs are functionally identical for boot purposes:

| File | systemd | sysvinit |
|------|---------|----------|
| Size | 1.38 GiB | 1.38 GiB |
| Boot sector | MBR (ISOLINUX) | MBR (ISOLINUX) |
| EFI support | ❌ None | ❌ None |
| Squashfs | 1.47 GB | 1.47 GB |
| Kernel | Same | Same |
| Init system | systemd | sysvinit |

**Difference:** The init system and services inside `live.squashfs` differ, but the boot mechanism is identical.

---

## Summary

| Aspect | Status |
|--------|--------|
| **ISO Boot Mode** | BIOS-only (MBR, ISOLINUX) |
| **UEFI Support** | ❌ Missing (`/EFI/BOOT/BOOTX64.EFI` absent) |
| **VirtualBox 7.x** | Requires disabling EFI in VM settings |
| **VirtualBox 6.1** | Should boot by default |
| **Real Hardware** | Requires CSM/Legacy BIOS mode |
| **USB Creation** | Standard `dd` works (hybrid ISO) |
| **Fix Required** | Install `grub-efi-amd64` or `shim` in build process |

---

## References

- **ISOLINUX Documentation:** https://wiki.syslinux.org/wiki/index.php/ISOLINUX
- **El Torito Boot Standard:** https://en.wikipedia.org/wiki/El_Torito_(CD-ROM_standard)
- **VirtualBox Boot Modes:** https://docs.oracle.com/en/virtualization/virtualbox/7.0/user/vboxconfigdata.html
- **GRUB EFI Installation:** https://www.gnu.org/software/grub/manual/grub/html_node/Installing-GRUB-using-grub_002dinstall.html
- **ProjectLookingGlass Profile:** See `builder.py` `ProfileManager.get_profile('lg3d')`

---

**Document Version:** 1.0  
**Last Updated:** 2026-11-03  
**Applies to:** LG3D nightly builds from `lg3d.yml` workflow
