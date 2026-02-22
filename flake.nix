{
  description = "zig flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig.url = "github:mitchellh/zig-overlay";
    zls.url = "github:zigtools/zls";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, zig, zls, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            zig.packages.${system}."0.15.2"
            zls.packages.${system}.zls
            glfw
            vulkan-loader
            vulkan-headers
            vulkan-tools
            vulkan-validation-layers
            vulkan-tools-lunarg
            shaderc
            lldb
          ];
        };
      });
}

