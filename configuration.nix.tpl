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

  # Roll back rpool/local/root to blank snapshot on every boot.
  # This runs in the scripted initrd after ZFS pools are imported but before
  # any filesystem is mounted — the same pattern as btrfs impermanence using
  # postResumeCommands.  The scripted initrd automatically creates mount-point
  # directories (mkdir -p) before mounting each filesystem, so the root
  # dataset can be completely empty after rollback.
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    zfs rollback -r rpool/local/root@blank
  '';

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
