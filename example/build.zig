const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vk_kickstart = b.dependency("vk_kickstart", .{
        .verbose = true,
        .target = target,
        .optimize = optimize,
    });

    const vulkan = vk_kickstart.module("vulkan");

    const sdl = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });

    const vma = b.dependency("vma_zig", .{
        .target = target,
        .optimize = optimize,
    });
    vma.module("vma-zig").addImport("vulkan", vulkan);

    const exe = b.addExecutable(.{
        .name = "kickstart_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vk-kickstart", .module = vk_kickstart.module("vk-kickstart") },
                .{ .name = "vulkan", .module = vulkan },
                .{ .name = "sdl", .module = sdl.module("sdl3") },
                .{ .name = "vma", .module = vma.module("vma-zig") },
            },
        }),
    });

    addShader(b, exe, "shaders/shader.vert", "shader_vert");
    addShader(b, exe, "shaders/shader.frag", "shader_frag");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn addShader(b: *std.Build, step: *std.Build.Step.Compile, path: []const u8, name: []const u8) void {
    const output_name = std.mem.concat(b.allocator, u8, &.{ path, ".spv" }) catch @panic("OOM");

    const shaderc = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.4", "-o" });
    const shader_spv = shaderc.addOutputFileArg(output_name);
    shaderc.addFileArg(b.path(path));

    step.root_module.addAnonymousImport(name, .{ .root_source_file = shader_spv });
}
