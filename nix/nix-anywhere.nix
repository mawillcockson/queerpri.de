{
  nixpkgs ? builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-25.11.tar.gz?rev=15826d42656cb99d69d429aee8c0ce2a486275d0";
    sha256 = "z5NJPSBwsLf/OfD8WTmh79tlSU8XgIbwmk6qB1/TFzY=";
  },
  system ? "x86_64-linux",
  hostname ? "queerpri.de",
}:
let
  pkgs = import nixpkgs {
    config = { };
    overlays = [ ];
    inherit system;
  };
  fs = pkgs.lib.fileset;
  dir = fs.toSource {
    root = ./.;
    fileset = fs.unions [
      ./flake.nix
      ./flake.lock
      ./configuration.nix
      ./hardware-configuration.nix
      ./disk-config.nix
    ];
  };
in
rec {
  nix-anywhere-script = pkgs.writeTextFile {
    name = "nix-anywhere-script";
    text = ''
      #!${pkgs.nushell}/bin/nu
      $env.NIX_CONFIG = 'extra-experimental-features = nix-command flakes pipe-operators'
      $env.NIX_PATH = $'nixpkgs=${nixpkgs}:nixos-config=(pwd)/configuration.nix'
      $env.PATH = $env.PATH | append [${"${pkgs.nixos-anywhere}/bin"}, ${"${pkgs.nixos-rebuild}/bin"}, ${"${pkgs.nix}/bin"}]

      nixos-anywhere --flake .#hetzner-cloud --generate-hardware-config nixos-generate-config ./hardware-configuration.nix ${hostname}
    '';
    executable = true;
  };
  run-nix-anywhere = pkgs.runCommandWith {
    name = "run-nix-anywhere";
    stdenv = pkgs.stdenvNoCC;
    runLocal = true;
  } "exec ${nix-anywhere-script}";
}
