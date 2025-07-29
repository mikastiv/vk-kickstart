const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const maybe_registry = b.option([]const u8, "registry", "Path to the Vulkan registry");
    if (maybe_registry == null) std.log.warn("no vk.xml path provided, using library's version (1.3.283)", .{});

    const registry = maybe_registry orelse b.pathFromRoot("vk.xml");
    const enable_validation = b.option(bool, "enable_validation", "Enable vulkan validation layers");
    const verbose = b.option(bool, "verbose", "Enable debug output");

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_validation", enable_validation orelse false);
    build_options.addOption(bool, "verbose", verbose orelse false);

    const vkzig_dep = b.dependency("vulkan", .{
        .registry = registry,
    });

    const kickstart = b.addModule("vk-kickstart", .{
        .root_source_file = b.path("src/vk_kickstart.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vulkan", .module = vkzig_dep.module("vulkan-zig") },
        },
    });
    kickstart.addOptions("build_options", build_options);
}
