{
  description = "A Nix flake to assemble MATLAB installations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
    in
    flake-utils.lib.eachSystem supportedSystems (
      system: let
        pkgs = import nixpkgs { inherit system; };
        matlabNix = import ./nix { inherit pkgs system; };
      in {
        packages = matlabNix.packages // {
          default = matlabNix.packages."R2025b";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ uv ];
        };

        lib = matlabNix.lib;
      }
    ) // {
      overlays.default = final: prev: {
        matlab = (import ./nix { pkgs = final; }).packages;
      };
    };
}
