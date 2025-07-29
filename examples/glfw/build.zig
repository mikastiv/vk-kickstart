const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "kickstart_glfw_example",
        .root_module = root_module,
    });

    const xml_path: []const u8 = b.pathFromRoot("vk.xml");

    const vkzig_dep = b.dependency("vulkan", .{
        .registry = xml_path,
    });

    const kickstart_dep = b.dependency("vk_kickstart", .{
        .registry = xml_path,
        .enable_validation = if (optimize == .Debug) true else false,
        .verbose = true,
    });

    exe.root_module.addImport("vk-kickstart", kickstart_dep.module("vk-kickstart"));
    exe.root_module.addImport("vulkan", vkzig_dep.module("vulkan-zig"));

    const glfw = b.dependency("glfw", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    exe.linkLibrary(glfw.artifact("glfw"));
    exe.linkSystemLibrary("GL");

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
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    const hash = hasher.final();
    const hex = std.fmt.allocPrint(b.allocator, "{x}", .{hash}) catch @panic("OOM");
    const output_name = std.mem.join(b.allocator, "", &.{ hex, ".spv" }) catch @panic("OOM");

    const shaderc = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.2", "-o" });
    const shader_spv = shaderc.addOutputFileArg(output_name);
    shaderc.addFileArg(b.path(path));

    step.root_module.addAnonymousImport(name, .{ .root_source_file = shader_spv });
}
