#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

info()    { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()     { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

confirm() {
  local prompt="${1:-Continue?}"
  read -rp $'\n'"$prompt [y/N] " answer
  [[ "${answer,,}" == "y" ]] || die "Aborted by user."
}

run() {
  echo -e "\033[1;90m  \$ $*\033[0m"
  "$@" || die "Command failed: $*"
}

# Resolve a device path (e.g. /dev/sda, sda, /dev/nvme0n1) to its /dev/disk/by-id/ symlink.
# If the input is already a by-id path, it is returned as-is.
# Populates the DISK_BY_ID_MATCHES array with all matching by-id links.
resolve_disk_by_id() {
  local input="$1"
  DISK_BY_ID_MATCHES=()

  # Pass through if already a by-id path
  if [[ "$input" == /dev/disk/by-id/* ]]; then
    DISK_BY_ID_MATCHES+=("$input")
    return 0
  fi

  # Normalise bare names (e.g. "sda" → "/dev/sda")
  if [[ "$input" != /dev/* ]]; then
    input="/dev/$input"
  fi

  [[ -b "$input" ]] || { warn "$input is not a valid block device"; return 1; }

  local real_dev
  real_dev=$(readlink -f "$input")

  # Collect all by-id symlinks that point to this device (skip partition entries)
  local preferred=() fallback=()
  for link in /dev/disk/by-id/*; do
    [[ -L "$link" ]] || continue
    [[ "$link" == *-part* ]] && continue
    local target
    target=$(readlink -f "$link")
    if [[ "$target" == "$real_dev" ]]; then
      case "$link" in
        */ata-*|*/nvme-*|*/scsi-*) preferred+=("$link") ;;
        *) fallback+=("$link") ;;
      esac
    fi
  done

  # Preferred first, then fallback
  DISK_BY_ID_MATCHES=("${preferred[@]}" "${fallback[@]}")

  [[ ${#DISK_BY_ID_MATCHES[@]} -gt 0 ]] || {
    warn "No /dev/disk/by-id/ entry found for $input"
    return 1
  }
  return 0
}

# ─────────────────────────────────────────────
# Dependency check: envsubst (from gettext)
# ─────────────────────────────────────────────

if ! command -v envsubst &>/dev/null; then
  info "envsubst not found — re-launching inside nix-shell with gettext…"
  exec nix-shell -p gettext --run "bash \"$0\""
fi

# ─────────────────────────────────────────────
# Step 1: Inspect disks
# ─────────────────────────────────────────────

info "Step 1: Inspecting disks and device IDs"

echo ""
echo "══════════════════════════════════════════"
echo " lsblk"
echo "══════════════════════════════════════════"
lsblk

echo ""
echo "══════════════════════════════════════════"
echo " /dev/disk/by-id"
echo "══════════════════════════════════════════"
ls -l /dev/disk/by-id

# ─────────────────────────────────────────────
# Step 2: Collect install variables
# ─────────────────────────────────────────────

info "Step 2: Enter install variables"

echo ""
read -rp  "Disk (e.g. sda, /dev/sda, or /dev/disk/by-id/ata-...): " DISK_INPUT

if ! resolve_disk_by_id "$DISK_INPUT"; then
  die "Could not resolve '$DISK_INPUT' to a /dev/disk/by-id/ path."
fi

if [[ ${#DISK_BY_ID_MATCHES[@]} -eq 1 ]]; then
  DISK="${DISK_BY_ID_MATCHES[0]}"
  info "Resolved to: $DISK"
else
  echo ""
  echo "Multiple /dev/disk/by-id/ entries found for $DISK_INPUT:"
  for i in "${!DISK_BY_ID_MATCHES[@]}"; do
    echo "  $((i+1))) ${DISK_BY_ID_MATCHES[$i]}"
  done
  read -rp "Select [1-${#DISK_BY_ID_MATCHES[@]}]: " choice
  if [[ "$choice" -ge 1 && "$choice" -le ${#DISK_BY_ID_MATCHES[@]} ]] 2>/dev/null; then
    DISK="${DISK_BY_ID_MATCHES[$((choice-1))]}"
  else
    die "Invalid selection."
  fi
fi

read -rp  "Hostname: " HOSTNAME
read -rp  "Host ID (8 hex chars) [Enter to auto-generate]: " HOST_ID
if [[ -z "$HOST_ID" ]]; then
  HOST_ID=$(head -c4 /dev/urandom | od -A none -t x1 | tr -d ' \n')
  echo "Auto-generated Host ID: $HOST_ID"
fi
read -rp  "Username: " USERNAME
read -rsp "Password: " USER_PASSWORD; echo

# Hash the password for hashedPasswordFile (survives root rollback)
if command -v mkpasswd &>/dev/null; then
  HASHED_PASSWORD=$(mkpasswd -m sha-512 "$USER_PASSWORD")
else
  HASHED_PASSWORD=$(echo "$USER_PASSWORD" | openssl passwd -6 -stdin)
fi

STATE_VERSION=$(nixos-version 2>/dev/null | grep -oP '^\d+\.\d+') || STATE_VERSION="25.11"
echo "Detected NixOS state version: $STATE_VERSION"

echo ""
echo "Optionally, specify existing ZFS pools to import at boot (e.g. tank backup)."
read -rp "Extra ZFS pools (space-separated, or leave blank to skip): " EXTRA_POOLS_INPUT

if [[ -n "$EXTRA_POOLS_INPUT" ]]; then
  NIX_LIST=""
  for pool in $EXTRA_POOLS_INPUT; do
    NIX_LIST+="\"$pool\" "
  done
  EXTRA_ZFS_POOLS_LINE="  boot.zfs.extraPools = [ ${NIX_LIST}];"
else
  EXTRA_ZFS_POOLS_LINE=""
fi

export DISK HOSTNAME HOST_ID USERNAME STATE_VERSION EXTRA_ZFS_POOLS_LINE

echo ""
echo "══════════════════════════════════════════"
echo " Chosen variables"
echo "══════════════════════════════════════════"
printf '%s\n' \
  "DISK=$DISK" \
  "HOSTNAME=$HOSTNAME" \
  "HOST_ID=$HOST_ID" \
  "USERNAME=$USERNAME" \
  "PASSWORD=[hidden]" \
  "STATE_VERSION=$STATE_VERSION" \
  "EXTRA_ZFS_POOLS=${EXTRA_POOLS_INPUT:-(none)}"

confirm "Do these look correct? Proceeding will partition and format $DISK."

# ─────────────────────────────────────────────
# Step 3: Write disk-config.nix
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info "Step 3: Writing disk-config.nix"

envsubst '$DISK' \
  < "$SCRIPT_DIR/disk-config.nix.tpl" \
  > /tmp/disk-config.nix

success "disk-config.nix written to /tmp/disk-config.nix"

# ────────────────────────────────────────────��
# Step 4: Run disko
# ─────────────────────────────────────────────

info "Step 4: Running disko to partition, format, create BTRFS subvolumes, and mount"

run sudo nix run --extra-experimental-features "nix-command flakes" \
  github:nix-community/disko -- \
  --mode disko \
  /tmp/disk-config.nix

success "disko complete. Disk partitioned, formatted, BTRFS subvolumes created, all mounted under /mnt."

# ─────────────────────────────────────────────
# Step 5: Generate hardware configuration
# ─────────────────────────────────────────────

info "Step 5: Generating NixOS hardware configuration and creating persistent layout"

# Create persistent directory structure (survives root rotation)
run sudo mkdir -p /mnt/persistent/etc/nixos
run sudo mkdir -p /mnt/persistent/etc/ssh
run sudo mkdir -p /mnt/persistent/etc/NetworkManager/system-connections
run sudo mkdir -p /mnt/persistent/var/lib/nixos
run sudo mkdir -p /mnt/persistent/var/lib/NetworkManager
run sudo mkdir -p /mnt/persistent/passwords

# Write hashed password file
echo "$HASHED_PASSWORD" | sudo tee /mnt/persistent/passwords/"$USERNAME" >/dev/null
sudo chmod 600 /mnt/persistent/passwords/"$USERNAME"
success "Hashed password written to /mnt/persistent/passwords/$USERNAME"

run sudo nixos-generate-config --root /mnt

# Remove fileSystems and swapDevices from hardware-configuration.nix — disko manages these.
# Without this, both disko (disk-config.nix) and hardware-configuration.nix declare the same
# fileSystems entries with different device values, causing a NixOS evaluation conflict.
info "Stripping fileSystems/swapDevices from hardware-configuration.nix (disko manages these)"
sudo sed -i '/^  fileSystems\./,/^    };$/d' /mnt/etc/nixos/hardware-configuration.nix
sudo sed -i '/^  swapDevices/,/;$/d'         /mnt/etc/nixos/hardware-configuration.nix
success "hardware-configuration.nix cleaned — filesystem declarations left to disko"

# Copy generated hardware config to /persistent and copy disk config to both locations
run sudo cp /mnt/etc/nixos/hardware-configuration.nix /mnt/persistent/etc/nixos/hardware-configuration.nix
run sudo cp /tmp/disk-config.nix /mnt/persistent/etc/nixos/disk-config.nix
run sudo cp /tmp/disk-config.nix /mnt/etc/nixos/disk-config.nix
success "hardware-configuration.nix and disk-config.nix written to /mnt/persistent/etc/nixos/ and /mnt/etc/nixos/"

# ─────────────────────────────────────────────
# Step 6: Write configuration.nix
# ─────────────────────────────────────────────

info "Step 6: Writing configuration.nix"

envsubst '$HOSTNAME $HOST_ID $USERNAME $STATE_VERSION $EXTRA_ZFS_POOLS_LINE' \
  < "$SCRIPT_DIR/configuration.nix.tpl" \
  | sudo tee /mnt/persistent/etc/nixos/configuration.nix >/dev/null

# Also place in /mnt/etc/nixos/ so nixos-install can find it
# (impermanence bind-mounts /persistent/etc/nixos -> /etc/nixos after first boot)
run sudo cp /mnt/persistent/etc/nixos/configuration.nix /mnt/etc/nixos/configuration.nix

success "configuration.nix written to /mnt/persistent/etc/nixos/ and /mnt/etc/nixos/"

echo ""
echo "══════════════════════════════════════════"
echo " Final configuration.nix"
echo "══════════════════════════════════════════"
cat /mnt/persistent/etc/nixos/configuration.nix

# ─────────────────────────────────────────────
# Done — manual steps remaining
# ─────────────────────────────────────────────

echo ""
echo -e "\033[1;32m════════════════════════════════════════════════\033[0m"
echo -e "\033[1;32m  Setup complete. Perform these steps manually:\033[0m"
echo -e "\033[1;32m════════════════════════════════════════════════\033[0m"
echo ""
echo "  1. Review the config above and confirm it looks correct."
echo ""
echo "  2. Run the installer:"
echo "       sudo nixos-install --no-root-passwd"
echo ""
echo "  3. Reboot into the installed system:"
echo "       reboot"
echo ""
echo "  4. Log in as: $USERNAME"
echo "     with password: [the one you entered]"
echo ""
echo -e "  \033[1;33mNote:\033[0m The root BTRFS subvolume is recreated fresh on"
echo "  every boot. Old roots are kept for 30 days under /old_roots."
echo "  All persistent state lives under /persistent."
echo "  NixOS configs are at /persistent/etc/nixos/ and bind-mounted"
echo "  into /etc/nixos/."
echo ""
echo "  When adding new services, persist their state by adding paths"
echo "  to environment.persistence.\"/persistent\" in configuration.nix."
echo ""
