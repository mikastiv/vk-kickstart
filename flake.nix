{
  description = "zig flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      url = "github:zigtools/zls/ce6c8f02c78e622421cfc2405c67c5222819ec03";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zig,
      zls,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
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
      }
    );
}
