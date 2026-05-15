{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
    "${builtins.fetchTarball "https://github.com/nix-community/disko/archive/master.tar.gz"}/module.nix"
    "${builtins.fetchTarball "https://github.com/nix-community/impermanence/archive/master.tar.gz"}/nixos.nix"
  ];

  networking.hostName = "$HOSTNAME";
  networking.hostId = "$HOST_ID";
  networking.networkmanager.enable = true;

  boot.supportedFilesystems = [ "zfs" ];
$EXTRA_ZFS_POOLS_LINE

  # Use the systemd-based initrd so the rollback service below is honoured.
  # (The scripted initrd silently ignores boot.initrd.systemd.services.)
  boot.initrd.systemd.enable = true;

  # Roll back rpool/local/root to blank snapshot on every boot, then create
  # mount-point directories so the initrd can mount /nix, /persist, etc.
  # The @blank snapshot captures an empty dataset, so without the mkdir step
  # the mount units for neededForBoot filesystems fail and the boot deadlocks.
  boot.initrd.systemd.services.rollback = {
    description = "Rollback ZFS root to blank snapshot";
    wantedBy = [ "initrd.target" ];
    requires = [ "zfs-import-rpool.service" ];
    after = [ "zfs-import-rpool.service" ];
    before = [ "sysroot.mount" ];
    path = [ config.boot.zfs.package ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      zfs rollback -r rpool/local/root@blank

      # The blank snapshot is an empty dataset — mount-point directories for
      # /nix, /persist, /home, and /boot do not exist yet.  Create them now
      # so that sysroot.mount and the neededForBoot mounts succeed.
      mount -t zfs rpool/local/root /sysroot
      mkdir -p /sysroot/{nix,persist,home,boot}
      umount /sysroot
    '';
  };

  boot.loader.grub.enable = true;
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.device = "nodev";
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  # Ensure /nix and /persist are mounted in the initrd before switch-root.
  # Without /nix the initrd cannot find stage-2 systemd (lives in /nix/store).
  fileSystems."/nix".neededForBoot = true;
  fileSystems."/persist".neededForBoot = true;

  # Persist state across reboots via impermanence
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/etc/nixos"
      "/etc/NetworkManager/system-connections"
      "/var/lib/nixos"
      "/var/lib/NetworkManager"
    ];
    files = [
      "/etc/machine-id"
    ];
  };

  # Generate SSH host keys into /persist so they survive rollback
  services.openssh = {
    enable = true;
    hostKeys = [
      { path = "/persist/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
      { path = "/persist/etc/ssh/ssh_host_rsa_key"; type = "rsa"; bits = 4096; }
    ];
  };

  users.users.$USERNAME = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    hashedPasswordFile = "/persist/passwords/$USERNAME";
  };

  system.stateVersion = "$STATE_VERSION";
}
