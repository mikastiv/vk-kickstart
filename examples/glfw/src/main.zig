const std = @import("std");
const c = @import("c.zig");
const vk = @import("vulkan");
const vkk = @import("vk-kickstart");
const Window = @import("Window.zig");
const GraphicsContext = @import("GraphicsContext.zig");
const Device = GraphicsContext.Device;
const Queue = GraphicsContext.Queue;
const CommandBuffer = GraphicsContext.CommandBuffer;

pub const vkk_options = struct {
    // Constants below remove the need for an allocator. They all have default
    // values but can be overriden if they are too big/small.

    // Instance override
    pub const instance_override = struct {
        // pub const max_extensions = 64;
        // pub const max_layers = 64;
    };

    // Physical device override
    pub const physical_device_override = struct {
        // pub const max_handles = 6;
        // pub const max_enabled_extensions = 16;
        // pub const max_available_extensions = 512;
        // pub const max_queue_families = 16;
    };

    // Swapchain override
    pub const swapchain_override = struct {
        // pub const max_surface_formats = 32;
    };
};

const max_frames_in_flight = 2;

const SyncObjects = struct {
    image_available_semaphores: [max_frames_in_flight]vk.Semaphore,
    render_finished_semaphores: [max_frames_in_flight]vk.Semaphore,
    in_flight_fences: [max_frames_in_flight]vk.Fence,
};

const FrameSyncObjects = struct {
    image_available_semaphore: vk.Semaphore,
    render_finished_semaphore: vk.Semaphore,
    in_flight_fence: vk.Fence,
};

fn errorCallback(error_code: i32, description: [*c]const u8) callconv(.C) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

const window_width = 800;
const window_height = 600;

pub fn main() !void {
    _ = c.glfwSetErrorCallback(errorCallback);

    if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const window = try Window.init(allocator, window_width, window_height, "vk-kickstart");
    defer window.deinit(allocator);

    var ctx = try GraphicsContext.init(allocator, window);
    defer ctx.deinit(allocator);

    const device = ctx.device;

    var swapchain = try vkk.Swapchain.create(
        device.handle,
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

    var images = try allocator.alloc(vk.Image, swapchain.image_count);
    defer allocator.free(images);

    try swapchain.getImages(images);

    var image_views = try allocator.alloc(vk.ImageView, swapchain.image_count);
    defer allocator.free(image_views);

    try swapchain.getImageViews(images, image_views, null);
    defer {
        for (image_views) |view| {
            device.destroyImageView(view, null);
        }
    }

    const render_pass = try createRenderPass(device, swapchain.image_format);
    defer device.destroyRenderPass(render_pass, null);

    var framebuffers = try createFramebuffers(allocator, device, swapchain.extent, swapchain.image_count, image_views, render_pass);
    defer destroyFramebuffers(allocator, device, framebuffers);

    const sync = try createSyncObjects(device);
    defer destroySyncObjects(device, sync);

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
    var should_recreate_swapchain = false;
    while (!window.shouldClose()) {
        c.glfwPollEvents();

        if (should_recreate_swapchain) {
            swapchain = try recreateSwapchain(
                allocator,
                &ctx,
                window,
                &swapchain,
                &images,
                &image_views,
                render_pass,
                &framebuffers,
            );
            should_recreate_swapchain = false;
        }

        if (window.framebuffer_resized) {
            should_recreate_swapchain = true;
            window.framebuffer_resized = false;
            continue;
        }

        const result = try device.waitForFences(1, @ptrCast(&sync.in_flight_fences[current_frame]), vk.TRUE, std.math.maxInt(u64));
        std.debug.assert(result == .success);

        const next_image_result = device.acquireNextImageKHR(
            swapchain.handle,
            std.math.maxInt(u64),
            sync.image_available_semaphores[current_frame],
            .null_handle,
        ) catch |err| {
            if (err == error.OutOfDateKHR) {
                should_recreate_swapchain = true;
                continue;
            }
            return err;
        };
        std.debug.assert(next_image_result.result == .success);

        const image_index = next_image_result.image_index;
        try recordCommandBuffer(&ctx, command_buffers[current_frame], pipeline, render_pass, framebuffers[image_index], swapchain.extent);

        const frame_sync_objects = FrameSyncObjects{
            .image_available_semaphore = sync.image_available_semaphores[current_frame],
            .render_finished_semaphore = sync.render_finished_semaphores[current_frame],
            .in_flight_fence = sync.in_flight_fences[current_frame],
        };
        if (!try drawFrame(
            &ctx,
            command_buffers[current_frame],
            frame_sync_objects,
            swapchain.handle,
            image_index,
        )) {
            should_recreate_swapchain = true;
        }

        current_frame = (current_frame + 1) % max_frames_in_flight;
    }

    try device.deviceWaitIdle();
}

fn drawFrame(
    ctx: *const GraphicsContext,
    command_buffer: vk.CommandBuffer,
    sync: FrameSyncObjects,
    swapchain: vk.SwapchainKHR,
    image_index: u32,
) !bool {
    const wait_semaphores = [_]vk.Semaphore{sync.image_available_semaphore};
    const wait_stages = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
    const signal_semaphores = [_]vk.Semaphore{sync.render_finished_semaphore};
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

    const fences = [_]vk.Fence{sync.in_flight_fence};
    try ctx.device.resetFences(fences.len, &fences);

    const submits = [_]vk.SubmitInfo{submit_info};
    try ctx.graphics_queue.submit(submits.len, &submits, sync.in_flight_fence);

    const indices = [_]u32{image_index};
    const swapchains = [_]vk.SwapchainKHR{swapchain};
    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = signal_semaphores.len,
        .p_wait_semaphores = &signal_semaphores,
        .swapchain_count = swapchains.len,
        .p_swapchains = &swapchains,
        .p_image_indices = &indices,
    };

    const present_result = ctx.present_queue.presentKHR(&present_info) catch |err| {
        if (err == error.OutOfDateKHR) {
            return false;
        }
        return err;
    };

    if (present_result == .suboptimal_khr) {
        return false;
    }

    return true;
}

fn recreateSwapchain(
    allocator: std.mem.Allocator,
    ctx: *const GraphicsContext,
    window: *Window,
    old_swapchain: *vkk.Swapchain,
    images: *[]vk.Image,
    image_views: *[]vk.ImageView,
    render_pass: vk.RenderPass,
    framebuffers: *[]vk.Framebuffer,
) !vkk.Swapchain {
    var extent = window.extent();
    while (extent.width == 0 or extent.height == 0) {
        extent = window.extent();
        c.glfwWaitEvents();
    }

    try ctx.device.deviceWaitIdle();

    const swapchain = try vkk.Swapchain.create(
        ctx.device.handle,
        ctx.physical_device.handle,
        old_swapchain.surface,
        .{
            .graphics_queue_index = ctx.graphics_queue_index,
            .present_queue_index = ctx.present_queue_index,
            .desired_extent = .{ .width = extent.width, .height = extent.height },
            .old_swapchain = old_swapchain.handle,
        },
        null,
    );

    for (image_views.*) |view| {
        ctx.device.destroyImageView(view, null);
    }
    ctx.device.destroySwapchainKHR(old_swapchain.handle, null);

    destroyFramebuffers(allocator, ctx.device, framebuffers.*);

    try swapchain.getImages(images.*);
    try swapchain.getImageViews(images.*, image_views.*, null);
    framebuffers.* = try createFramebuffers(
        allocator,
        ctx.device,
        extent,
        swapchain.image_count,
        image_views.*,
        render_pass,
    );

    return swapchain;
}

fn destroyFramebuffers(allocator: std.mem.Allocator, device: Device, framebuffers: []const vk.Framebuffer) void {
    for (framebuffers) |framebuffer| {
        device.destroyFramebuffer(framebuffer, null);
    }
    allocator.free(framebuffers);
}

fn destroySyncObjects(device: Device, sync: SyncObjects) void {
    for (sync.image_available_semaphores) |semaphore| {
        device.destroySemaphore(semaphore, null);
    }
    for (sync.render_finished_semaphores) |semaphore| {
        device.destroySemaphore(semaphore, null);
    }
    for (sync.in_flight_fences) |fence| {
        device.destroyFence(fence, null);
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
    const cmd = CommandBuffer.init(command_buffer, ctx.vkd);

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
        .primitive_restart_enable = vk.FALSE,
    };

    const rasterizer_info = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .line_width = 1,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
    };

    const multisampling_info = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const color_blend_attachments = [_]vk.PipelineColorBlendAttachmentState{.{
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    }};

    const color_blend_info = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
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

fn createSyncObjects(device: Device) !SyncObjects {
    var image_available_semaphores = [_]vk.Semaphore{.null_handle} ** max_frames_in_flight;
    var render_finished_semaphores = [_]vk.Semaphore{.null_handle} ** max_frames_in_flight;
    var in_flight_fences = [_]vk.Fence{.null_handle} ** max_frames_in_flight;
    errdefer {
        for (image_available_semaphores) |semaphore| {
            if (semaphore == .null_handle) continue;
            device.destroySemaphore(semaphore, null);
        }
        for (render_finished_semaphores) |semaphore| {
            if (semaphore == .null_handle) continue;
            device.destroySemaphore(semaphore, null);
        }
        for (in_flight_fences) |fence| {
            if (fence == .null_handle) continue;
            device.destroyFence(fence, null);
        }
    }

    const semaphore_info = vk.SemaphoreCreateInfo{};
    const fence_info = vk.FenceCreateInfo{ .flags = .{ .signaled_bit = true } };
    for (0..max_frames_in_flight) |i| {
        image_available_semaphores[i] = try device.createSemaphore(&semaphore_info, null);
        render_finished_semaphores[i] = try device.createSemaphore(&semaphore_info, null);
        in_flight_fences[i] = try device.createFence(&fence_info, null);
    }

    return .{
        .image_available_semaphores = image_available_semaphores,
        .render_finished_semaphores = render_finished_semaphores,
        .in_flight_fences = in_flight_fences,
    };
}

fn createFramebuffers(
    allocator: std.mem.Allocator,
    device: Device,
    extent: vk.Extent2D,
    image_count: u32,
    image_views: []vk.ImageView,
    render_pass: vk.RenderPass,
) ![]vk.Framebuffer {
    var framebuffers = try std.ArrayList(vk.Framebuffer).initCapacity(allocator, image_count);
    errdefer {
        for (framebuffers.items) |framebuffer| {
            device.destroyFramebuffer(framebuffer, null);
        }
        framebuffers.deinit();
    }

    for (0..image_count) |i| {
        const attachments = [_]vk.ImageView{image_views[i]};
        const framebuffer_info = vk.FramebufferCreateInfo{
            .render_pass = render_pass,
            .attachment_count = attachments.len,
            .p_attachments = &attachments,
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        };

        const framebuffer = try device.createFramebuffer(&framebuffer_info, null);
        try framebuffers.append(framebuffer);
    }

    return framebuffers.toOwnedSlice();
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
