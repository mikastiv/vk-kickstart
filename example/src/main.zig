const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const vkk = @import("vk-kickstart");
const c = @import("c.zig");
const GraphicsContext = @import("GraphicsContext.zig");
const Device = GraphicsContext.Device;
const Queue = GraphicsContext.Queue;
const CommandBuffer = GraphicsContext.CommandBuffer;

const glfw_log = std.log.scoped(.glfw);

const max_frames_in_flight = 2;

const FrameSyncObjects = struct {
    image_available_semaphore: vk.Semaphore,
    in_flight_fence: vk.Fence,

    const empty: FrameSyncObjects = .{
        .image_available_semaphore = .null_handle,
        .in_flight_fence = .null_handle,
    };
};

const ImageSyncObjects = struct {
    render_finished_semaphore: vk.Semaphore,

    const empty: ImageSyncObjects = .{
        .render_finished_semaphore = .null_handle,
    };
};

const WindowData = struct {
    framebuffer_resized: bool,
};

const window_width = 800;
const window_height = 600;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    _ = c.glfwSetErrorCallback(&glfwErrorCallback);

    if (c.glfwInit() != c.GLFW_TRUE) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    if (c.glfwVulkanSupported() != c.GLFW_TRUE) {
        glfw_log.err("Glfw could not find libvulkan", .{});
        return error.GlfwNoVulkan;
    }

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

    const window = c.glfwCreateWindow(
        window_width,
        window_height,
        "Tutorial",
        null,
        null,
    ) orelse return error.GlfwWindowInitFailed;
    defer c.glfwDestroyWindow(window);

    var window_data: WindowData = .{
        .framebuffer_resized = false,
    };

    c.glfwSetWindowUserPointer(window, &window_data);

    _ = c.glfwSetKeyCallback(window, &glfwKeyCallback);
    _ = c.glfwSetFramebufferSizeCallback(window, &glfwFramebufferCallback);

    const allocator = switch (builtin.mode) {
        .Debug => debug_allocator.allocator(),
        else => std.heap.smp_allocator,
    };
    defer if (builtin.mode == .Debug) {
        _ = debug_allocator.deinit();
    };

    var ctx = try GraphicsContext.init(allocator, window);
    defer ctx.deinit();

    const device = ctx.device;

    var swapchain = try vkk.Swapchain.create(
        allocator,
        ctx.instance,
        ctx.device,
        ctx.physical_device.handle,
        ctx.surface,
        .{
            .graphics_queue_index = ctx.graphics_queue_index,
            .present_queue_index = ctx.present_queue_index,
            .desired_extent = .{ .width = window_width, .height = window_height },
        },
        null,
    );
    defer device.destroySwapchainKHR(swapchain.handle, null);

    const images = try device.getSwapchainImagesAllocKHR(swapchain.handle, allocator);
    defer allocator.free(images);

    const image_views = try swapchain.getImageViewsAlloc(allocator, images, null);
    defer {
        for (image_views) |view| {
            device.destroyImageView(view, null);
        }
        allocator.free(image_views);
    }

    const render_pass = try createRenderPass(device, swapchain.image_format);
    defer device.destroyRenderPass(render_pass, null);

    const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.image_count);
    defer allocator.free(framebuffers);

    try createFramebuffers(device, swapchain.extent, image_views, render_pass, framebuffers);
    defer {
        for (framebuffers) |framebuffer| {
            device.destroyFramebuffer(framebuffer, null);
        }
    }

    const frame_sync = try createFrameSyncObjects(device);
    defer destroyFrameSyncObjects(device, frame_sync);

    const image_sync = try createImageSyncObjects(allocator, device, swapchain.image_count);
    defer destroyImageSyncObjects(allocator, device, image_sync);

    const vertex_shader_bytes align(@alignOf(u32)) = @embedFile("shader_vert").*;
    const vertex_shader = try createShaderModule(device, &vertex_shader_bytes);
    defer device.destroyShaderModule(vertex_shader, null);
    const fragment_shader_bytes align(@alignOf(u32)) = @embedFile("shader_frag").*;
    const fragment_shader = try createShaderModule(device, &fragment_shader_bytes);
    defer device.destroyShaderModule(fragment_shader, null);

    const pipeline_layout_info = vk.PipelineLayoutCreateInfo{};
    const pipeline_layout = try device.createPipelineLayout(&pipeline_layout_info, null);
    defer device.destroyPipelineLayout(pipeline_layout, null);

    const pipeline = try createGraphicsPipeline(device, render_pass, vertex_shader, fragment_shader, pipeline_layout);
    defer device.destroyPipeline(pipeline, null);

    const command_pool = try createCommandPool(device, ctx.graphics_queue_index);
    defer device.destroyCommandPool(command_pool, null);

    const command_buffers = try createCommandBuffers(allocator, device, command_pool, max_frames_in_flight);
    defer allocator.free(command_buffers);

    var current_frame: u32 = 0;
    while (c.glfwWindowShouldClose(window) != c.GLFW_TRUE) {
        c.glfwPollEvents();

        if (window_data.framebuffer_resized) {
            swapchain = try recreateSwapchain(
                allocator,
                &ctx,
                window,
                &swapchain,
                images,
                image_views,
                render_pass,
                framebuffers,
            );

            window_data.framebuffer_resized = false;
        }

        const result = try device.waitForFences(1, @ptrCast(&frame_sync[current_frame].in_flight_fence), .true, std.math.maxInt(u64));
        std.debug.assert(result == .success);

        const next_image_result = device.acquireNextImageKHR(
            swapchain.handle,
            std.math.maxInt(u64),
            frame_sync[current_frame].image_available_semaphore,
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => {
                window_data.framebuffer_resized = true;
                continue;
            },
            else => return err,
        };

        const image_index = next_image_result.image_index;
        try recordCommandBuffer(&ctx, command_buffers[current_frame], pipeline, render_pass, framebuffers[image_index], swapchain.extent);

        const frame_sync_objects: FrameSyncObjects = .{
            .image_available_semaphore = frame_sync[current_frame].image_available_semaphore,
            .in_flight_fence = frame_sync[current_frame].in_flight_fence,
        };
        const image_sync_objects: ImageSyncObjects = .{
            .render_finished_semaphore = image_sync[image_index].render_finished_semaphore,
        };

        window_data.framebuffer_resized = !try drawFrame(
            &ctx,
            command_buffers[current_frame],
            frame_sync_objects,
            image_sync_objects,
            swapchain.handle,
            image_index,
        );

        current_frame = (current_frame + 1) % max_frames_in_flight;
    }

    try device.deviceWaitIdle();
}

fn drawFrame(
    ctx: *const GraphicsContext,
    command_buffer: vk.CommandBuffer,
    frame_sync: FrameSyncObjects,
    image_sync: ImageSyncObjects,
    swapchain: vk.SwapchainKHR,
    image_index: u32,
) !bool {
    const wait_semaphores = [_]vk.Semaphore{frame_sync.image_available_semaphore};
    const wait_stages = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
    const signal_semaphores = [_]vk.Semaphore{image_sync.render_finished_semaphore};
    const command_buffers = [_]vk.CommandBuffer{command_buffer};
    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = wait_semaphores.len,
        .p_wait_semaphores = &wait_semaphores,
        .p_wait_dst_stage_mask = &wait_stages,
        .command_buffer_count = command_buffers.len,
        .p_command_buffers = &command_buffers,
        .signal_semaphore_count = signal_semaphores.len,
        .p_signal_semaphores = &signal_semaphores,
    };

    const fences = [_]vk.Fence{frame_sync.in_flight_fence};
    try ctx.device.resetFences(fences.len, &fences);

    const submits = [_]vk.SubmitInfo{submit_info};
    try ctx.graphics_queue.submit(submits.len, &submits, frame_sync.in_flight_fence);

    const indices = [_]u32{image_index};
    const swapchains = [_]vk.SwapchainKHR{swapchain};
    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = signal_semaphores.len,
        .p_wait_semaphores = &signal_semaphores,
        .swapchain_count = swapchains.len,
        .p_swapchains = &swapchains,
        .p_image_indices = &indices,
    };

    const present_result = ctx.present_queue.presentKHR(&present_info) catch |err| switch (err) {
        error.OutOfDateKHR => return false,
        else => return err,
    };

    if (present_result == .suboptimal_khr) {
        return false;
    }

    return true;
}

fn recreateSwapchain(
    allocator: std.mem.Allocator,
    ctx: *const GraphicsContext,
    window: *c.GLFWwindow,
    old_swapchain: *const vkk.Swapchain,
    images: []vk.Image,
    image_views: []vk.ImageView,
    render_pass: vk.RenderPass,
    framebuffers: []vk.Framebuffer,
) !vkk.Swapchain {
    var width: c_int = undefined;
    var height: c_int = undefined;
    c.glfwGetFramebufferSize(window, &width, &height);
    while (width == 0 or height == 0) {
        c.glfwGetFramebufferSize(window, &width, &height);
        c.glfwWaitEvents();
    }

    try ctx.device.deviceWaitIdle();

    const swapchain = try vkk.Swapchain.create(
        allocator,
        ctx.instance,
        ctx.device,
        ctx.physical_device.handle,
        old_swapchain.surface,
        .{
            .graphics_queue_index = ctx.graphics_queue_index,
            .present_queue_index = ctx.present_queue_index,
            .desired_extent = .{ .width = @intCast(width), .height = @intCast(height) },
            .old_swapchain = old_swapchain.handle,
        },
        null,
    );

    for (image_views) |view| {
        ctx.device.destroyImageView(view, null);
    }
    ctx.device.destroySwapchainKHR(old_swapchain.handle, null);

    for (framebuffers) |framebuffer| {
        ctx.device.destroyFramebuffer(framebuffer, null);
    }

    try swapchain.getImages(images);
    try swapchain.getImageViews(images, image_views, null);
    try createFramebuffers(ctx.device, swapchain.extent, image_views, render_pass, framebuffers);

    return swapchain;
}

fn destroyImageSyncObjects(
    allocator: std.mem.Allocator,
    device: Device,
    objects: []ImageSyncObjects,
) void {
    for (objects) |object| {
        device.destroySemaphore(object.render_finished_semaphore, null);
    }
    allocator.free(objects);
}

fn destroyFrameSyncObjects(device: Device, objects: [max_frames_in_flight]FrameSyncObjects) void {
    for (objects) |object| {
        device.destroySemaphore(object.image_available_semaphore, null);
        device.destroyFence(object.in_flight_fence, null);
    }
}

fn recordCommandBuffer(
    ctx: *const GraphicsContext,
    command_buffer: vk.CommandBuffer,
    pipeline: vk.Pipeline,
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,
    extent: vk.Extent2D,
) !void {
    const begin_info = vk.CommandBufferBeginInfo{};
    try ctx.device.beginCommandBuffer(command_buffer, &begin_info);
    const cmd = CommandBuffer.init(command_buffer, ctx.device.wrapper);

    const clear_values = [_]vk.ClearValue{
        .{ .color = .{ .float_32 = .{ 0.1, 0.1, 0.1, 1 } } },
    };
    const render_pass_begin_info = vk.RenderPassBeginInfo{
        .render_pass = render_pass,
        .framebuffer = framebuffer,
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        },
        .clear_value_count = clear_values.len,
        .p_clear_values = &clear_values,
    };

    cmd.beginRenderPass(&render_pass_begin_info, .@"inline");

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    cmd.setViewport(0, 1, @ptrCast(&viewport));

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };
    cmd.setScissor(0, 1, @ptrCast(&scissor));

    cmd.bindPipeline(.graphics, pipeline);

    cmd.draw(3, 1, 0, 0);

    cmd.endRenderPass();
    try ctx.device.endCommandBuffer(command_buffer);
}

fn createCommandBuffers(
    allocator: std.mem.Allocator,
    device: Device,
    command_pool: vk.CommandPool,
    count: u32,
) ![]vk.CommandBuffer {
    const command_buffers = try allocator.alloc(vk.CommandBuffer, count);
    errdefer allocator.free(command_buffers);

    const command_buffer_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = count,
    };
    try device.allocateCommandBuffers(&command_buffer_info, command_buffers.ptr);

    return command_buffers;
}

fn createCommandPool(device: Device, queue_family_index: u32) !vk.CommandPool {
    const create_info = vk.CommandPoolCreateInfo{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = queue_family_index,
    };
    return device.createCommandPool(&create_info, null);
}

fn createGraphicsPipeline(
    device: Device,
    render_pass: vk.RenderPass,
    vertex_shader: vk.ShaderModule,
    fragment_shader: vk.ShaderModule,
    pipeline_layout: vk.PipelineLayout,
) !vk.Pipeline {
    const shader_stages = [2]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vertex_shader,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = fragment_shader,
            .p_name = "main",
        },
    };

    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic_state_info = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    const viewport_state_info = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .scissor_count = 1,
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{};

    const input_assembly_info = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const rasterizer_info = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .line_width = 1,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
    };

    const multisampling_info = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const color_blend_attachments = [_]vk.PipelineColorBlendAttachmentState{.{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    }};

    const color_blend_info = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = color_blend_attachments.len,
        .p_attachments = &color_blend_attachments,
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    const pipeline_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = shader_stages.len,
        .p_stages = &shader_stages,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly_info,
        .p_viewport_state = &viewport_state_info,
        .p_rasterization_state = &rasterizer_info,
        .p_multisample_state = &multisampling_info,
        .p_color_blend_state = &color_blend_info,
        .p_dynamic_state = &dynamic_state_info,
        .layout = pipeline_layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_index = -1,
    };

    var graphics_pipeline: vk.Pipeline = .null_handle;
    const result = try device.createGraphicsPipelines(
        .null_handle,
        1,
        @ptrCast(&pipeline_info),
        null,
        @ptrCast(&graphics_pipeline),
    );
    errdefer device.destroyPipeline(graphics_pipeline, null);

    if (result != .success) return error.PipelineCreationFailed;

    return graphics_pipeline;
}

fn createShaderModule(device: Device, bytecode: []align(4) const u8) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = bytecode.len,
        .p_code = std.mem.bytesAsSlice(u32, bytecode).ptr,
    };

    return device.createShaderModule(&create_info, null);
}

fn createImageSyncObjects(
    allocator: std.mem.Allocator,
    device: Device,
    image_count: u32,
) ![]ImageSyncObjects {
    var objects = try allocator.alloc(ImageSyncObjects, image_count);
    @memset(objects, .empty);
    errdefer {
        for (objects) |object| {
            if (object.render_finished_semaphore == .null_handle) continue;
            device.destroySemaphore(object.render_finished_semaphore, null);
        }
    }

    const semaphore_info = vk.SemaphoreCreateInfo{};
    for (0..objects.len) |i| {
        objects[i].render_finished_semaphore = try device.createSemaphore(&semaphore_info, null);
    }

    return objects;
}

fn createFrameSyncObjects(device: Device) ![max_frames_in_flight]FrameSyncObjects {
    var objects: [max_frames_in_flight]FrameSyncObjects = @splat(.empty);
    errdefer {
        for (objects) |object| {
            if (object.image_available_semaphore == .null_handle) continue;
            device.destroySemaphore(object.image_available_semaphore, null);
            device.destroyFence(object.in_flight_fence, null);
        }
    }

    const semaphore_info = vk.SemaphoreCreateInfo{};
    const fence_info = vk.FenceCreateInfo{ .flags = .{ .signaled_bit = true } };
    for (0..objects.len) |i| {
        objects[i].image_available_semaphore = try device.createSemaphore(&semaphore_info, null);
        objects[i].in_flight_fence = try device.createFence(&fence_info, null);
    }

    return objects;
}

fn createFramebuffers(
    device: Device,
    extent: vk.Extent2D,
    image_views: []vk.ImageView,
    render_pass: vk.RenderPass,
    framebuffers: []vk.Framebuffer,
) !void {
    std.debug.assert(image_views.len == framebuffers.len);

    errdefer {
        for (framebuffers) |framebuffer| {
            device.destroyFramebuffer(framebuffer, null);
        }
    }

    for (0..framebuffers.len) |i| {
        const attachments = [_]vk.ImageView{image_views[i]};
        const framebuffer_info = vk.FramebufferCreateInfo{
            .render_pass = render_pass,
            .attachment_count = attachments.len,
            .p_attachments = &attachments,
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        };

        framebuffers[i] = try device.createFramebuffer(&framebuffer_info, null);
    }
}

fn createRenderPass(device: Device, image_format: vk.Format) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .format = image_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_attachment_refs = [_]vk.AttachmentReference{.{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    }};

    const subpasses = [_]vk.SubpassDescription{.{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = color_attachment_refs.len,
        .p_color_attachments = &color_attachment_refs,
    }};

    const dependencies = [_]vk.SubpassDependency{.{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
    }};

    const attachments = [_]vk.AttachmentDescription{color_attachment};
    const renderpass_info = vk.RenderPassCreateInfo{
        .attachment_count = attachments.len,
        .p_attachments = &attachments,
        .subpass_count = subpasses.len,
        .p_subpasses = &subpasses,
        .dependency_count = dependencies.len,
        .p_dependencies = &dependencies,
    };

    return device.createRenderPass(&renderpass_info, null);
}

fn glfwFramebufferCallback(window: ?*c.GLFWwindow, _: c_int, _: c_int) callconv(.c) void {
    const window_data: *WindowData = @ptrCast(c.glfwGetWindowUserPointer(window));
    window_data.framebuffer_resized = true;
}

fn glfwErrorCallback(
    error_code: c_int,
    description: [*c]const u8,
) callconv(.c) void {
    glfw_log.err("{d}: {s}\n", .{ error_code, description });
}

fn glfwKeyCallback(
    window: ?*c.GLFWwindow,
    key: c_int,
    _: c_int,
    action: c_int,
    _: c_int,
) callconv(.c) void {
    if (key == c.GLFW_KEY_ESCAPE and action == c.GLFW_PRESS) {
        c.glfwSetWindowShouldClose(window, c.GLFW_TRUE);
    }
}
