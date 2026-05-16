# nix-nas

Declarative NixOS configuration for a BTRFS-based NAS/server with optional ZFS storage pools.

This repository provides a single interactive install script that takes a NixOS live ISO to a fully working system with:

- **BTRFS-on-root** via [disko](https://github.com/nix-community/disko) — automated partitioning and subvolume creation
- **Impermanence** via [nix-community/impermanence](https://github.com/nix-community/impermanence) — the root subvolume is recreated fresh on every boot; only explicitly persisted state survives
- **Persistent state** under `/persistent` — NixOS configs, SSH host keys, NetworkManager connections, and user password hashes all live on a dedicated BTRFS subvolume
- **Optional ZFS pool imports** — external ZFS pools (e.g. RAID arrays for bulk storage) can be auto-imported at boot
- **GRUB with UEFI** boot and a separate `/boot` partition (ext4) for kernel/initrd

---

## Table of Contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Installation](#installation)
4. [Post-Install Verification](#post-install-verification)
5. [Troubleshooting](#troubleshooting)

---

## Architecture

### Disk Layout

The install script uses disko to create a GPT partition table with three partitions:

| Partition | Size | Format | Mount Point |
|-----------|------|--------|-------------|
| ESP | 512 MB | FAT32 | `/boot/efi` |
| boot | 2 GB | ext4 | `/boot` |
| root | Remaining | BTRFS | *(subvolumes below)* |

### BTRFS Subvolume Layout

```
BTRFS partition
├── root         →  /            (recreated fresh every boot)
├── nix          →  /nix         (Nix store — survives reboot)
├── persistent   →  /persistent  (all persistent system state)
├── home         →  /home        (user home directories)
└── old_roots/                   (previous roots, auto-deleted after 30 days)
    ├── 2026-05-14_10:30:00
    └── ...
```

All subvolumes are mounted with `compress=zstd` and `noatime` for performance.

### Root Rotation

On every boot, the initrd rotates the root subvolume before mounting filesystems:

1. Mount the BTRFS partition to a temporary directory
2. Move the current `root` subvolume to `old_roots/<timestamp>`
3. Delete any old roots older than 30 days
4. Create a fresh, empty `root` subvolume
5. Unmount the temporary directory

This is handled by `boot.initrd.postResumeCommands` in `configuration.nix`, following the [impermanence BTRFS guide](https://github.com/nix-community/impermanence#btrfs-subvolumes).

After rotation, `/` starts completely empty each boot. Anything that needs to survive must be:
- Stored under `/persistent` (BTRFS subvolume)
- Declared in `environment.persistence."/persistent"` in `configuration.nix`

Unlike ZFS rollback, old roots are preserved for 30 days. This provides a safety net — if something goes wrong, you can recover files from previous boots by mounting the BTRFS partition and inspecting `old_roots/`.

### Template System

The install script uses `envsubst` to render two Nix template files:

- **`disk-config.nix.tpl`** → `/persistent/etc/nixos/disk-config.nix` (substitutes `$DISK`)
- **`configuration.nix.tpl`** → `/persistent/etc/nixos/configuration.nix` (substitutes `$HOSTNAME`, `$HOST_ID`, `$USERNAME`, `$STATE_VERSION`, `$EXTRA_ZFS_POOLS_LINE`)

The generated `hardware-configuration.nix` is created by `nixos-generate-config` and placed alongside them in `/persistent/etc/nixos/`.

---

## Prerequisites

### What You Need

- **NixOS ISO** — Download the minimal or graphical installer from [nixos.org/download](https://nixos.org/download/)
- **Network access** — The install script fetches disko and impermanence from GitHub at build time
- **One target disk** — The script will partition the entire disk; all existing data will be destroyed

### Information to Gather

Before starting, decide on the following:

| Variable | Example | Notes |
|----------|---------|-------|
| Disk path | `/dev/disk/by-id/ata-WDC_WD40EFAX-...` | Use by-id path, not `/dev/sdX` |
| Hostname | `nas01` | System hostname |
| Host ID | `a1b2c3d4` | 8 hex characters (required if importing ZFS pools); auto-generated if left blank |
| Username | `admin` | Your login user (added to `wheel` group) |
| Password | *(prompted securely)* | Hashed with SHA-512 and stored in `/persistent` |
| Extra ZFS pools | `tank backup` | Optional — existing ZFS pools to auto-import at boot |

### Bare-Metal Preparation

1. Write the NixOS ISO to a USB drive:
   ```bash
   sudo dd if=nixos-minimal-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```
   Or use [Etcher](https://etcher.balena.io/) / [Ventoy](https://www.ventoy.net/).

2. Plug the USB into the target machine and boot from it.
3. **Ensure UEFI mode** — enter BIOS/firmware setup and confirm the machine boots in UEFI mode, not legacy BIOS. Disable Secure Boot if it interferes.

### Virtual Machine Preparation

1. Create a VM with:
   - **Firmware: UEFI** (not legacy BIOS) — this is critical
   - At least **2 GB RAM** (4 GB+ recommended for nixos-install)
   - A virtual disk large enough for your use case (20 GB minimum for testing)
2. Attach the NixOS ISO as a virtual CD-ROM and boot from it.

> **VM tip (QEMU/libvirt):** Use `-bios /usr/share/OVMF/OVMF_CODE.fd` or select UEFI firmware in virt-manager.
>
> **VM tip (VirtualBox):** Settings → System → Enable EFI.
>
> **VM tip (Proxmox):** Hardware → BIOS → select OVMF (UEFI).

---

## Installation

### Step 1 — Boot the NixOS Installer

Boot from the USB drive or ISO. You will land at a root shell (minimal ISO) or a desktop (graphical ISO).

### Step 2 — Connect to the Network

**Wired:** Should work automatically via DHCP. Verify with:
```bash
ip a
ping -c 2 nixos.org
```

**Wi-Fi:**
```bash
nmtui
```
Select "Activate a connection", choose your network, enter the password.

### Step 3 — Get This Repository

```bash
nix-shell -p git --run "git clone https://github.com/<your-user>/nix-nas.git /tmp/nix-nas"
```

Alternatively, if the repo is private or you prefer not to use git:
```bash
# Copy files from another machine via scp, USB, etc.
scp user@other-machine:~/nix-nas/* /tmp/nix-nas/
```

### Step 4 — Run the Install Script

```bash
cd /tmp/nix-nas
sudo bash install.sh
```

The script will walk you through each step interactively:

1. **Disk inspection** — displays `lsblk` and `/dev/disk/by-id` so you can identify your target disk
2. **Variable collection** — prompts for disk path, hostname, host ID, username, password, and optional extra ZFS pools
3. **Confirmation** — shows your choices and asks you to confirm before destructive operations
4. **Disko** — partitions the disk, creates the BTRFS subvolumes, mounts everything under `/mnt`
5. **Hardware config** — runs `nixos-generate-config`, sets up `/persistent` directory structure, writes hashed password file
6. **Configuration** — renders `configuration.nix` and `disk-config.nix` from templates into `/mnt/persistent/etc/nixos/`

At the end, the script prints the final `configuration.nix` for you to review.

### Step 5 — Review and Install

Review the printed configuration. If everything looks correct:

```bash
sudo nixos-install --no-root-passwd
```

> `--no-root-passwd` is used because the root account has no password; you log in as your created user who has `wheel` (sudo) access.

This will build the full system closure and install it to `/mnt`. It may take several minutes depending on your network speed and hardware.

### Step 6 — Reboot

```bash
reboot
```

Remove the USB drive or ISO when prompted (or adjust boot order in BIOS/VM settings).

---

## Post-Install Verification

After rebooting, log in with the username and password you chose during installation. Then run through these checks:

### BTRFS Filesystem Health

```bash
sudo btrfs filesystem show
```

Expect the BTRFS partition to appear with the correct device. Then list subvolumes:

```bash
sudo btrfs subvolume list /
```

You should see `root`, `nix`, `persistent`, and `home` subvolumes.

### Root Rotation

Verify root rotation is working by creating a test file and rebooting:

```bash
sudo touch /rotation-test
ls /rotation-test   # should exist now
sudo reboot
# after reboot:
ls /rotation-test   # should be gone
```

> **If `/rotation-test` is still present after reboot**, root rotation is not executing. See [Root Rotation Not Working](#root-rotation-not-working) in Troubleshooting.

Check that old roots are being preserved:

```bash
sudo mount /dev/disk/by-partlabel/disk-main-root /mnt
ls /mnt/old_roots/
sudo umount /mnt
```

You should see timestamped directories from previous boots.

### Persistence

Check that persisted directories are properly bind-mounted:

```bash
mount | grep persistent
```

You should see bind mounts for `/etc/nixos`, `/etc/NetworkManager/system-connections`, `/var/lib/nixos`, and `/var/lib/NetworkManager`.

Verify configs are in place:

```bash
ls /persistent/etc/nixos/
# Should contain: configuration.nix  disk-config.nix  hardware-configuration.nix
```

### SSH

```bash
systemctl status sshd
```

Should show `active (running)`. Verify host keys are persisted:

```bash
ls -la /persistent/etc/ssh/
# Should contain ssh_host_ed25519_key and ssh_host_rsa_key (plus .pub files)
```

Test from another machine:

```bash
ssh <username>@<ip-address>
```

### Networking

```bash
ip a                       # check interfaces are up
ping -c 2 nixos.org        # verify internet access
networkctl status          # overview of network state
```

### Boot Loader

```bash
efibootmgr
```

Should list a NixOS entry. Verify GRUB is installed:

```bash
ls /boot/efi/EFI/
```

### Extra ZFS Pools (If Configured)

If you specified extra pools during installation:

```bash
sudo zpool status <pool-name>
```

Each pool should show `state: ONLINE`.

---

## Troubleshooting

### Disk Not Found

- Run `ls /dev/disk/by-id/` and double-check the path
- SATA, NVMe, and USB disks have different path prefixes (`ata-`, `nvme-`, `usb-`)
- **VM:** Ensure the virtual disk controller is recognized (use VirtIO or SATA, not IDE)

### Disko Fails

- Disko fetches its code from GitHub at runtime — ensure you have internet access
- Test with: `curl -I https://github.com`
- If behind a proxy, configure `http_proxy` / `https_proxy` environment variables

### Boot Fails After Install

- Enter BIOS/firmware and set the installed disk as the first boot device
- Verify UEFI mode was used during install (legacy BIOS won't find the ESP)
- **VM:** Confirm the VM firmware is set to UEFI/OVMF, not legacy BIOS
- If GRUB is missing, boot back into the live ISO, mount, and re-run install:
  ```bash
  sudo mount /dev/disk/by-partlabel/disk-main-root /mnt -o subvol=root
  sudo mkdir -p /mnt/{nix,home,persistent,boot}
  sudo mount /dev/disk/by-partlabel/disk-main-root /mnt/nix -o subvol=nix
  sudo mount /dev/disk/by-partlabel/disk-main-root /mnt/home -o subvol=home
  sudo mount /dev/disk/by-partlabel/disk-main-root /mnt/persistent -o subvol=persistent
  sudo mount /dev/disk/by-label/boot /mnt/boot        # adjust label as needed
  sudo mkdir -p /mnt/boot/efi
  sudo mount /dev/disk/by-label/ESP /mnt/boot/efi      # adjust label as needed
  sudo nixos-install --root /mnt --no-root-passwd
  ```

### Root Rotation Not Working

If `/rotation-test` persists after reboot (see [Post-Install Verification](#post-install-verification)), work through these steps in order:

**1. Check the initrd boot log**

```bash
sudo journalctl -b | grep -i "btrfs\|subvolume\|old_roots"
```

Look for errors during the `postResumeCommands` execution.

**2. Verify the BTRFS partition is accessible**

```bash
ls /dev/disk/by-partlabel/disk-main-root
```

If missing, the disko partition labels may differ. Check `ls /dev/disk/by-partlabel/` and update `configuration.nix` accordingly.

**3. Test manual rotation**

```bash
sudo mkdir -p /tmp/btrfs_tmp
sudo mount /dev/disk/by-partlabel/disk-main-root /tmp/btrfs_tmp
ls /tmp/btrfs_tmp/
# You should see: root, nix, persistent, home (and old_roots if rotation has worked before)
sudo umount /tmp/btrfs_tmp
```

**4. Verify subvolume mount**

```bash
mount | grep "subvol"
```

Ensure `/` is mounted with `subvol=root` (or `subvol=/root`).

**5. Rebuild and reboot**

After making any configuration changes:

```bash
sudo nixos-rebuild switch
sudo reboot
```

Then re-run the rotation test (`sudo touch /rotation-test && sudo reboot`).

### `envsubst: command not found`

The install script uses `envsubst` (from GNU `gettext`) to render template files. If it isn't available (common on the minimal NixOS ISO), the script automatically re-launches itself inside `nix-shell -p gettext` to provide it. You will see:

```
[INFO]  envsubst not found — re-launching inside nix-shell with gettext…
```

This requires network access (to fetch the `gettext` package), which the script already needs for disko and impermanence. No action is required on your part.

### `fileSystems` Conflicting Definition Values

If `nixos-install` fails with:

```
error: The option 'fileSystems."/boot".device' has conflicting definition values
```

This means `hardware-configuration.nix` contains `fileSystems` entries that conflict with disko's declarations in `disk-config.nix`. The install script automatically strips these during generation, but if you regenerate `hardware-configuration.nix` manually, you must remove the `fileSystems` and `swapDevices` blocks from it — disko manages all filesystem declarations.

### Password Not Working

- The hashed password lives at `/persistent/passwords/<username>`
- Verify it exists and has correct permissions:
  ```bash
  sudo ls -la /persistent/passwords/
  ```
- To reset, boot the live ISO, mount the partition, and overwrite:
  ```bash
  sudo mount /dev/disk/by-partlabel/disk-main-root /mnt -o subvol=persistent
  mkpasswd -m sha-512 "newpassword" | sudo tee /mnt/passwords/<username>
  ```

### Adding New Services

When you add services that store state (databases, containers, etc.), persist their data directories by adding them to `environment.persistence."/persistent"` in `configuration.nix`:

```nix
environment.persistence."/persistent" = {
  directories = [
    # ... existing entries ...
    "/var/lib/my-new-service"
  ];
};
```

Then rebuild:

```bash
sudo nixos-rebuild switch
```

### Recovering Files from Old Roots

One advantage of BTRFS root rotation over ZFS rollback is that old roots are preserved for 30 days. If you accidentally lost a file:

```bash
sudo mkdir -p /tmp/btrfs_tmp
sudo mount /dev/disk/by-partlabel/disk-main-root /tmp/btrfs_tmp
ls /tmp/btrfs_tmp/old_roots/
# Browse timestamped directories to find your file
sudo cp /tmp/btrfs_tmp/old_roots/<timestamp>/path/to/file /destination
sudo umount /tmp/btrfs_tmp
```
