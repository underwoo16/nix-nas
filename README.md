# nix-nas

Declarative NixOS configuration for a ZFS-based NAS/server.

This repository provides a single interactive install script that takes a NixOS live ISO to a fully working system with:

- **ZFS-on-root** via [disko](https://github.com/nix-community/disko) — automated partitioning and dataset creation
- **Impermanence** via [nix-community/impermanence](https://github.com/nix-community/impermanence) — the root dataset (`rpool/local/root`) is rolled back to a blank snapshot on every boot; only explicitly persisted state survives
- **Persistent state** under `/persist` — NixOS configs, SSH host keys, NetworkManager connections, and user password hashes all live on a dedicated ZFS dataset (`rpool/safe/persist`)
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
| zfs | Remaining | ZFS pool `rpool` | *(datasets below)* |

### ZFS Dataset Layout

```
rpool
├── local/root   →  /        (rolled back to @blank snapshot every boot)
├── local/nix    →  /nix     (Nix store — survives rollback)
├── safe/home    →  /home    (user home directories)
└── safe/persist →  /persist (all persistent system state)
```

### Root Rollback

On every boot, the initrd rolls back the root dataset before it is mounted:

```bash
zfs rollback -r rpool/local/root@blank
```

This is configured for both initrd types (scripted and systemd) so the rollback works regardless of your NixOS version or initrd configuration.

This means `/` starts fresh each boot. Anything that needs to survive must be:
- Stored under `/persist` (ZFS dataset `rpool/safe/persist`)
- Declared in `environment.persistence."/persist"` in `configuration.nix`

### Template System

The install script uses `envsubst` to render two Nix template files:

- **`disk-config.nix.tpl`** → `/persist/etc/nixos/disk-config.nix` (substitutes `$DISK`)
- **`configuration.nix.tpl`** → `/persist/etc/nixos/configuration.nix` (substitutes `$HOSTNAME`, `$HOST_ID`, `$USERNAME`, `$STATE_VERSION`, `$EXTRA_ZFS_POOLS_LINE`)

The generated `hardware-configuration.nix` is created by `nixos-generate-config` and placed alongside them in `/persist/etc/nixos/`.

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
| Host ID | `a1b2c3d4` | 8 hex characters (required by ZFS); auto-generated if left blank |
| Username | `admin` | Your login user (added to `wheel` group) |
| Password | *(prompted securely)* | Hashed with SHA-512 and stored in `/persist` |
| Extra ZFS pools | `tank backup` | Optional — existing pools to auto-import at boot |

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
sudo bash nix-zfs-root-install.sh
```

The script will walk you through each step interactively:

1. **Disk inspection** — displays `lsblk` and `/dev/disk/by-id` so you can identify your target disk
2. **Variable collection** — prompts for disk path, hostname, host ID, username, password, and optional extra ZFS pools
3. **Confirmation** — shows your choices and asks you to confirm before destructive operations
4. **Disko** — partitions the disk, creates the ZFS pool and datasets, mounts everything under `/mnt`
5. **Hardware config** — runs `nixos-generate-config`, sets up `/persist` directory structure, writes hashed password file
6. **Configuration** — renders `configuration.nix` and `disk-config.nix` from templates into `/mnt/persist/etc/nixos/`

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

### ZFS Pool Health

```bash
sudo zpool status rpool
```

Expect `state: ONLINE` with no errors. Then list all datasets:

```bash
sudo zfs list
```

You should see `rpool/local/root`, `rpool/local/nix`, `rpool/safe/home`, and `rpool/safe/persist`.

### Root Rollback

Verify the blank snapshot exists:

```bash
sudo zfs list -t snapshot
```

You should see `rpool/local/root@blank`. Since the root dataset is rolled back on every boot, creating a file in `/` and rebooting should make it disappear:

```bash
sudo touch /rollback-test
ls /rollback-test   # should exist now
sudo reboot
# after reboot:
ls /rollback-test   # should be gone
```

> **If `/rollback-test` is still present after reboot**, the rollback is not executing. See [Root Rollback Not Working](#root-rollback-not-working) in Troubleshooting.

### Persistence

Check that persisted directories are properly bind-mounted:

```bash
mount | grep persist
```

You should see bind mounts for `/etc/nixos`, `/etc/NetworkManager/system-connections`, `/var/lib/nixos`, and `/var/lib/NetworkManager`.

Verify configs are in place:

```bash
ls /persist/etc/nixos/
# Should contain: configuration.nix  disk-config.nix  hardware-configuration.nix
```

### SSH

```bash
systemctl status sshd
```

Should show `active (running)`. Verify host keys are persisted:

```bash
ls -la /persist/etc/ssh/
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
- If GRUB is missing, boot back into the live ISO, import the pool, mount, and re-run install:
  ```bash
  sudo zpool import -f rpool
  sudo mount -t zfs rpool/local/root /mnt
  sudo mount -t zfs rpool/local/nix /mnt/nix
  sudo mount -t zfs rpool/safe/persist /mnt/persist
  sudo mount /dev/disk/by-label/boot /mnt/boot        # adjust label as needed
  sudo mount /dev/disk/by-label/ESP /mnt/boot/efi      # adjust label as needed
  sudo nixos-install --root /mnt --no-root-passwd
  ```

### ZFS Pool Won't Import

```bash
sudo zpool import           # list available pools
sudo zpool import -f rpool  # force import (e.g. after unclean shutdown)
```

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

### Root Rollback Not Working

If `/rollback-test` persists after reboot (see [Post-Install Verification](#post-install-verification)), work through these steps in order:

**1. Check which initrd type is active**

```bash
# If this path exists, systemd initrd is in use
ls /run/initramfs/etc/systemd/ 2>/dev/null && echo "systemd initrd" || echo "scripted initrd"
```

The `boot.initrd.postDeviceCommands` hook only runs under the **scripted initrd**. If your system uses the **systemd initrd** (common in NixOS 23.11+), that hook is silently ignored. The configuration template includes a `boot.initrd.systemd.services.rollback` service to handle this case — verify it is present:

```bash
grep -A5 "systemd.services.rollback" /persist/etc/nixos/configuration.nix
```

If the systemd rollback service is missing, add it to your `configuration.nix` (see the template in this repo) and rebuild:

```bash
sudo nixos-rebuild switch
```

**2. Verify the blank snapshot exists**

```bash
sudo zfs list -t snapshot | grep blank
```

Expected: `rpool/local/root@blank`. If missing, create it:

```bash
sudo zfs snapshot rpool/local/root@blank
```

**3. Verify `postDeviceCommands` is set (scripted initrd)**

```bash
grep -A2 "postDeviceCommands" /persist/etc/nixos/configuration.nix
```

Should show the `zfs rollback` line. If missing, the template may not have rendered correctly.

**4. Test manual rollback**

```bash
sudo zfs rollback -r rpool/local/root@blank
```

If this errors with "more recent snapshots or clones exist", list and remove them:

```bash
sudo zfs list -t snapshot -r rpool/local/root
sudo zfs destroy rpool/local/root@<offending-snapshot>
```

**5. Rebuild and reboot**

After making any configuration changes:

```bash
sudo nixos-rebuild switch
sudo reboot
```

Then re-run the rollback test (`sudo touch /rollback-test && sudo reboot`).

### Password Not Working

- The hashed password lives at `/persist/passwords/<username>`
- Verify it exists and has correct permissions:
  ```bash
  sudo ls -la /persist/passwords/
  ```
- To reset, boot the live ISO, import the pool, and overwrite:
  ```bash
  sudo zpool import -f rpool
  sudo mount -t zfs rpool/safe/persist /mnt
  mkpasswd -m sha-512 "newpassword" | sudo tee /mnt/passwords/<username>
  ```

### Adding New Services

When you add services that store state (databases, containers, etc.), persist their data directories by adding them to `environment.persistence."/persist"` in `configuration.nix`:

```nix
environment.persistence."/persist" = {
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
