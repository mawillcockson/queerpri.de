{
  modulesPath,
  ...
}:

let
  diskDevice = "/dev/sda";
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-25.11.tar.gz?rev=15826d42656cb99d69d429aee8c0ce2a486275d0";
    sha256 = "z5NJPSBwsLf/OfD8WTmh79tlSU8XgIbwmk6qB1/TFzY=";
  };
  disko = builtins.fetchGit {
    url = "https://github.com/nix-community/disko.git";
    rev = "de5708739256238fb912c62f03988815db89ec9a"; # v1.13.0
    shallow = true;
  };
  pkgs = import nixpkgs {
    config = { };
    overlays = [ ];
    system = "x86_64-linux";
  };
in
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    (disko + "/module.nix")
    ./single-disk-layout.nix
  ];

  disko.devices.disk.main.device = diskDevice;

  boot.loader.grub = {
    devices = [ diskDevice ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  services.openssh.enable = true;

  users.users.root.openssh.authorizedKeys.keyFiles = [
    (builtins.fetchurl "https://github.com/mawillcockson.keys")
  ];

  system.stateVersion = "25.11";
}
