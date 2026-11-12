{
  modulesPath,
  lib,
  pkgs,
  ...
}@args:
let
  rootHashedPasswordFile =
    pkgs.runCommandWith
      {
        name = "make-hashed-password";
        runLocal = true;
        stdenv = pkgs.stdenvNoCC;
        derivationArgs.nativeBuildInputs = [ pkgs.mkpasswd ];
      }
      ''
        printf 'password' | mkpasswd --method=scrypt --stdin > "$out"
      '';

in
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./single-disk-layout.nix
  ];
  boot.loader.grub = {
    # no need to set devices, disko will add all devices that have a EF02 partition to the list already
    # devices = [ ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  services.openssh.enable = true;

  environment.systemPackages = map lib.lowPrio [
    pkgs.curl
    pkgs.gitMinimal
  ];

  # I could use `users.users.root.initialPassword`, but I want to do this the hard way
  users.users.root.initialHashedPassword =
    builtins.readFile rootHashedPasswordFile |> pkgs.lib.strings.trim;
  users.users.root.openssh.authorizedKeys.keys = [
    # change this to your ssh key
    (builtins.readFile (
      builtins.fetchurl {
        url = "https://github.com/mawillcockson.keys";
        sha256 = (
          builtins.convertHash {
            hash = "sha256:0q999sg3m2phnaqwhybzbv02h4y77ld4shmdz815rx342n5k9cav";
            toHashFormat = "nix32";
          }
        );
      }
    ))
  ]
  ++ (args.extraPublicKeys or [ ]); # this is used for unit-testing this module and can be removed if not needed

  system.stateVersion = "25.11";
}
