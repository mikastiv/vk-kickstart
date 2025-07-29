{
  description = "LLVM build flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            xorg.libX11
            xorg.libXext
            vulkan-loader
            vulkan-headers
            vulkan-tools
            vulkan-validation-layers
            libGL
            libGLU
            zls
            shaderc
          ];
        };
      });
}

