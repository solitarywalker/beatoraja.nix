{
  description = "beatoraja (BMS player) launcher packaged for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    jportaudio = {
      url = "github:solitarywalker/jportaudio.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      jportaudio,
    }:
    {
      overlays.default = final: prev: {
        beatoraja = final.callPackage ./beatoraja.nix {
          jportaudio = jportaudio.packages.${final.stdenv.hostPlatform.system}.default;
        };
      };

      # モジュール側では pkgs.callPackage で組むので、利用側の nixpkgs で
      # ビルドされる (この flake の nixpkgs 入力は使われない)。
      nixosModules.beatoraja = import ./module.nix { inherit jportaudio; };
      nixosModules.default = self.nixosModules.beatoraja;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        beatoraja = pkgs.callPackage ./beatoraja.nix {
          jportaudio = jportaudio.packages.${system}.default;
        };
      in
      {
        packages = {
          inherit beatoraja;
          default = beatoraja;
        };

        formatter = pkgs.nixfmt-tree;
      }
    );
}
