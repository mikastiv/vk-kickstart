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
            vulkan-tools-lunarg
            libGL
            libGLU
            zls
            shaderc
          ];

          LD_LIBRARY_PATH="${pkgs.vulkan-loader}/lib:${pkgs.vulkan-validation-layers}/lib";
          VULKAN_SDK = "${pkgs.vulkan-headers}";
          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
        };
      });
}

