{
  description = "zig flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    zig-flake.url = "github:silversquirl/zig-flake";
    zig-flake.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-flake,
    }:
    let
      forAllSystems =
        f:
        builtins.mapAttrs (
          system: pkgs: f pkgs zig-flake.packages.${system}.zig_0_17_0
        ) nixpkgs.legacyPackages;
    in
    {
      devShells = forAllSystems (
        pkgs: zig:
        let
          runtimeLibs = with pkgs; [
            wayland
            libdecor
            libxkbcommon
            vulkan-loader
          ];
        in
        {
          default = pkgs.mkShell {
            buildInputs = runtimeLibs;

            nativeBuildInputs = with pkgs; [
              vulkan-validation-layers
              vulkan-tools
              glsl_analyzer
              shaderc
              zig
              # zig.zls
            ];

            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (runtimeLibs);
          };
        }
      );

    };
}
