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
read -rp  "Disk path (e.g. /dev/disk/by-id/ata-YourDiskIDHere): " DISK
read -rp  "Hostname: " HOSTNAME
read -rp  "Host ID (8 hex chars, e.g. a1b2c3d4): " HOST_ID
read -rp  "Username: " USERNAME
read -rsp "Initial password: " INITIAL_PASSWORD; echo

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

export DISK HOSTNAME HOST_ID USERNAME INITIAL_PASSWORD STATE_VERSION EXTRA_ZFS_POOLS_LINE

echo ""
echo "══════════════════════════════════════════"
echo " Chosen variables"
echo "══════════════════════════════════════════"
printf '%s\n' \
  "DISK=$DISK" \
  "HOSTNAME=$HOSTNAME" \
  "HOST_ID=$HOST_ID" \
  "USERNAME=$USERNAME" \
  "INITIAL_PASSWORD=[hidden]" \
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

info "Step 4: Running disko to partition, format, create ZFS datasets, and mount"

run sudo nix run github:nix-community/disko -- \
  --mode disko \
  /tmp/disk-config.nix

success "disko complete. Disk partitioned, formatted, ZFS pool and datasets created, all mounted under /mnt."

# ─────────────────────────────────────────────
# Step 5: Generate hardware configuration
# ─────────────────────────────────────────────

info "Step 5: Generating NixOS hardware configuration"

run sudo nixos-generate-config --root /mnt
success "Hardware configuration generated at /mnt/etc/nixos/hardware-configuration.nix"

run sudo cp /tmp/disk-config.nix /mnt/etc/nixos/disk-config.nix
success "disk-config.nix copied to /mnt/etc/nixos/disk-config.nix"

# ─────────────────────────────────────────────
# Step 6: Write configuration.nix
# ─────────────────────────────────────────────

info "Step 6: Writing configuration.nix"

envsubst '$HOSTNAME $HOST_ID $USERNAME $INITIAL_PASSWORD $STATE_VERSION $EXTRA_ZFS_POOLS_LINE' \
  < "$SCRIPT_DIR/configuration.nix.tpl" \
  | sudo tee /mnt/etc/nixos/configuration.nix >/dev/null

success "configuration.nix written to /mnt/etc/nixos/configuration.nix"

echo ""
echo "══════════════════════════════════════════"
echo " Final configuration.nix"
echo "══════════════════════════════════════════"
cat /mnt/etc/nixos/configuration.nix

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
echo "       sudo nixos-install"
echo ""
echo "  3. When prompted, set a root password or leave blank if unneeded."
echo ""
echo "  4. Reboot into the installed system:"
echo "       reboot"
echo ""
echo "  5. Log in as: $USERNAME"
echo "     with password: [the one you entered]"
echo ""
echo "  6. After first boot, change your password:"
echo "       passwd"
echo ""
warn "Remember to change initialPassword after first login."
echo ""
