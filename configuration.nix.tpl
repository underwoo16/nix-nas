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

  # Use the systemd-based initrd.  The impermanence module provides a
  # create-needed-for-boot-dirs service that creates mount-point directories
  # on the (empty-after-rollback) root before sysroot.mount runs.
  boot.initrd.systemd.enable = true;

  # Roll back rpool/local/root to blank snapshot on every boot.
  # Runs after the ZFS pool is imported but before both sysroot.mount and
  # impermanence's create-needed-for-boot-dirs (which creates mount-point
  # directories on the empty root).  Without this ordering, the two services
  # race: if create-needed-for-boot-dirs runs first, rollback wipes its work.
  boot.initrd.systemd.services.rollback = {
    description = "Rollback ZFS root to blank snapshot";
    wantedBy = [ "initrd.target" ];
    requires = [ "zfs-import-rpool.service" ];
    after = [ "zfs-import-rpool.service" ];
    before = [ "sysroot.mount" "create-needed-for-boot-dirs.service" ];
    path = [ config.boot.zfs.package ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      zfs rollback -r rpool/local/root@blank
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
