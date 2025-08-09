const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const maybe_registry = b.option(std.Build.LazyPath, "registry", "Path to the Vulkan registry");
    if (maybe_registry == null) std.log.warn("no vk.xml path provided, pulling from https://github.com/KhronosGroup/Vulkan-Headers", .{});

    const registry = maybe_registry orelse b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
    const vk_gen = b.dependency("vulkan", .{}).artifact("vulkan-zig-generator");
    const vk_gen_cmd = b.addRunArtifact(vk_gen);
    vk_gen_cmd.addFileArg(registry);

    const vulkan = b.addModule("vulkan", .{
        .root_source_file = vk_gen_cmd.addOutputFileArg("vk.zig"),
    });

    const enable_validation = b.option(bool, "enable_validation", "Enable vulkan validation layers");
    const verbose = b.option(bool, "verbose", "Enable debug output");

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_validation", enable_validation orelse false);
    build_options.addOption(bool, "verbose", verbose orelse false);

    const kickstart = b.addModule("vk-kickstart", .{
        .root_source_file = b.path("src/vk_kickstart.zig"),
        .target = target,
        .optimize = optimize,
    });
    kickstart.addImport("vulkan", vulkan);
    kickstart.addOptions("build_options", build_options);
}
