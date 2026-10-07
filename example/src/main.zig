const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const sdl = @import("sdl");
const vk = @import("vulkan");
const vkk = @import("vk-kickstart");
const vma = @import("vma");

const Instance = vk.InstanceProxy;
const Device = vk.DeviceProxy;
const Queue = vk.QueueProxy;
const CommandBuffer = vk.CommandBufferProxy;

const sdl_log = std.log.scoped(.sdl);

const max_frames_in_flight = 2;

const FrameResource = struct {
    command_pool: vk.CommandPool,
    command_buffer: CommandBuffer,
    image_acquire_semaphore: vk.Semaphore,

    const empty: FrameResource = .{
        .command_pool = .null_handle,
        .command_buffer = undefined,
        .image_acquire_semaphore = .null_handle,
    };
};

const Swapchain = struct {
    handle: vk.SwapchainKHR,
    image_count: u32,
    width: u32,
    height: u32,
    image_format: vk.Format,
    images: []vk.Image,
    image_views: []vk.ImageView,
    depth_image: vk.Image,
    depth_image_allocation: vma.Allocation,
    depth_view: vk.ImageView,

    fn destroy(
        self: *const Swapchain,
        allocator: std.mem.Allocator,
        vma_allocator: vma.Allocator,
        device: Device,
    ) void {
        for (self.image_views) |view| {
            device.destroyImageView(view, null);
        }
        device.destroyImageView(self.depth_view, null);
        vma_allocator.destroyImage(self.depth_image, self.depth_image_allocation);

        device.destroySwapchainKHR(self.handle, null);

        allocator.free(self.image_views);
        allocator.free(self.images);
    }
};

const debug_mode = builtin.mode == .Debug;

fn logSdlError() void {
    sdl_log.err("{s}", .{sdl.SDL_GetError()});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    _ = io;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const allocator = switch (debug_mode) {
        true => debug_allocator.allocator(),
        false => std.heap.smp_allocator,
    };
    defer if (debug_mode) {
        _ = debug_allocator.deinit();
    };

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
        logSdlError();
        return error.SdlInitFailed;
    }
    defer sdl.SDL_Quit();

    if (!sdl.SDL_Vulkan_LoadLibrary(null)) {
        logSdlError();
        return error.SdlVulkanLoadFailed;
    }

    var window_width: u32 = 800;
    var window_height: u32 = 600;

    const window = sdl.SDL_CreateWindow(
        "Vulkan",
        @intCast(window_width),
        @intCast(window_height),
        sdl.SDL_WINDOW_VULKAN | sdl.SDL_WINDOW_RESIZABLE,
    ) orelse {
        logSdlError();
        return error.SdlCreateWindowFailed;
    };
    defer sdl.SDL_DestroyWindow(window);

    var instance_extensions_count: u32 = undefined;
    const instance_extensions = sdl.SDL_Vulkan_GetInstanceExtensions(&instance_extensions_count);

    const loader: vk.PfnGetInstanceProcAddr = @ptrCast(sdl.SDL_Vulkan_GetVkGetInstanceProcAddr());

    const instance = try vkk.instance.create(
        allocator,
        loader,
        .{
            .app_name = "Vulkan",
            .minimum_api_version = vk.API_VERSION_1_4,
            .required_extensions = @ptrCast(instance_extensions[0..instance_extensions_count]),
            .enabled_validation_features = &.{.best_practices_ext},
        },
        null,
    );
    defer {
        instance.destroyInstance(null);
        allocator.destroy(instance.wrapper);
    }

    const debug_messenger = switch (debug_mode) {
        true => try vkk.instance.createDebugMessenger(instance, .{}, null),
        false => .null_handle,
    };
    defer if (debug_mode) {
        vkk.instance.destroyDebugMessenger(instance, debug_messenger, null);
    };

    var surface: vk.SurfaceKHR = .null_handle;
    if (!sdl.SDL_Vulkan_CreateSurface(
        window,
        @ptrFromInt(@intFromEnum(instance.handle)),
        null,
        @ptrCast(&surface),
    )) {
        logSdlError();
        return error.SdlCreateSurfaceFailed;
    }
    defer instance.destroySurfaceKHR(surface, null);

    const physical_device = try vkk.PhysicalDevice.select(allocator, instance, .{
        .surface = surface,
        .preferred_types = &.{.discrete_gpu},
        .minimum_api_version = vk.API_VERSION_1_4,
        .required_extensions = &.{vk.extensions.khr_swapchain.name},
        .required_features_12 = .{
            .timeline_semaphore = .true,
        },
        .required_features_13 = .{
            .synchronization_2 = .true,
            .dynamic_rendering = .true,
        },
    });
    defer physical_device.deinit();

    const device = try vkk.device.create(allocator, instance, &physical_device, null, null);
    defer {
        device.destroyDevice(null);
        allocator.destroy(device.wrapper);
    }

    const gfx_queue_handle = device.getDeviceQueue(physical_device.graphics_queue_family_index, 0);
    const gfx_queue: Queue = .init(gfx_queue_handle, device.wrapper);

    const allocator_ci: vma.AllocatorCreateInfo = .{
        .flags = .{ .buffer_device_address_bit = true },
        .instance = instance.handle,
        .physical_device = physical_device.handle,
        .device = device.handle,
        .p_vulkan_functions = &.{
            .getInstanceProcAddr = @ptrCast(loader),
            .getDeviceProcAddr = @ptrCast(instance.wrapper.dispatch.vkGetDeviceProcAddr),
        },
        .vulkan_api_version = @bitCast(physical_device.properties.api_version),
    };
    const vma_allocator = try vma.Allocator.create(&allocator_ci);
    defer vma_allocator.destroy();

    const depth_format: vk.Format = .d32_sfloat;
    var swapchain = try createSwapchain(
        allocator,
        vma_allocator,
        instance,
        device,
        &physical_device,
        surface,
        depth_format,
        window_width,
        window_height,
        .null_handle,
    );
    defer swapchain.destroy(allocator, vma_allocator, device);

    var render_semaphores = try allocator.alloc(vk.Semaphore, swapchain.image_count);
    defer allocator.free(render_semaphores);

    for (render_semaphores) |*semaphore| {
        semaphore.* = try device.createSemaphore(&.{}, null);
    }
    defer {
        for (render_semaphores) |semaphore| {
            device.destroySemaphore(semaphore, null);
        }
    }

    const vertex_shader_bytes align(@alignOf(u32)) = @embedFile("shader_vert").*;
    const vertex_shader = try createShaderModule(device, &vertex_shader_bytes);
    defer device.destroyShaderModule(vertex_shader, null);

    const fragment_shader_bytes align(@alignOf(u32)) = @embedFile("shader_frag").*;
    const fragment_shader = try createShaderModule(device, &fragment_shader_bytes);
    defer device.destroyShaderModule(fragment_shader, null);

    const pipeline_layout = try device.createPipelineLayout(&.{}, null);
    defer device.destroyPipelineLayout(pipeline_layout, null);

    const pipeline = try createGraphicsPipeline(
        device,
        vertex_shader,
        fragment_shader,
        pipeline_layout,
        swapchain.image_format,
        depth_format,
    );
    defer device.destroyPipeline(pipeline, null);

    const timeline_semaphore_type_ci: vk.SemaphoreTypeCreateInfo = .{
        .semaphore_type = .timeline,
        .initial_value = max_frames_in_flight,
    };
    const timeline_semaphore_ci: vk.SemaphoreCreateInfo = .{
        .p_next = &timeline_semaphore_type_ci,
    };
    const timeline_semaphore = try device.createSemaphore(&timeline_semaphore_ci, null);
    defer device.destroySemaphore(timeline_semaphore, null);

    const frame_resources = try createFrameResources(device, physical_device.graphics_queue_family_index);
    defer destroyFrameResources(device, frame_resources);

    var frame_index: u32 = 0;
    var next_signal_value: u64 = max_frames_in_flight + 1;
    var recreate_swapchain = false;
    loop: while (true) {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => {
                    break :loop;
                },
                sdl.SDL_EVENT_KEY_DOWN => {
                    if (event.key.key == sdl.SDLK_ESCAPE) {
                        break :loop;
                    }
                },
                sdl.SDL_EVENT_WINDOW_RESIZED => {
                    recreate_swapchain = true;
                },
                else => {},
            }
        }

        if (recreate_swapchain) {
            var width: c_int = 0;
            var height: c_int = 0;
            if (!sdl.SDL_GetWindowSize(window, &width, &height)) {
                logSdlError();
                continue :loop;
            }

            window_width = @intCast(width);
            window_height = @intCast(height);

            try device.deviceWaitIdle();

            const old_swapchain = swapchain;

            swapchain = try createSwapchain(
                allocator,
                vma_allocator,
                instance,
                device,
                &physical_device,
                surface,
                depth_format,
                window_width,
                window_height,
                old_swapchain.handle,
            );

            old_swapchain.destroy(allocator, vma_allocator, device);

            if (old_swapchain.image_count != swapchain.image_count) {
                for (render_semaphores) |semaphore| {
                    device.destroySemaphore(semaphore, null);
                }
                allocator.free(render_semaphores);

                render_semaphores = try allocator.alloc(vk.Semaphore, swapchain.image_count);
                for (render_semaphores) |*semaphore| {
                    semaphore.* = try device.createSemaphore(&.{}, null);
                }
            }

            recreate_swapchain = false;
        }

        const frame_resource = &frame_resources[frame_index];
        frame_index = (frame_index + 1) % max_frames_in_flight;

        const signal_value = next_signal_value;
        next_signal_value += 1;

        const wait_value = signal_value - max_frames_in_flight;

        const semaphore_wi: vk.SemaphoreWaitInfo = .{
            .semaphore_count = 1,
            .p_semaphores = @ptrCast(&timeline_semaphore),
            .p_values = @ptrCast(&wait_value),
        };
        const wait_result = try device.waitSemaphores(&semaphore_wi, std.math.maxInt(u64));
        assert(wait_result == .success);

        try device.resetCommandPool(frame_resource.command_pool, .{});

        const next_image_result = device.acquireNextImageKHR(
            swapchain.handle,
            std.math.maxInt(u64),
            frame_resource.image_acquire_semaphore,
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => {
                recreate_swapchain = true;
                continue;
            },
            else => return err,
        };

        if (next_image_result.result == .suboptimal_khr) {
            recreate_swapchain = true;
        }

        const image_index = next_image_result.image_index;
        const cb = frame_resource.command_buffer;

        try recordCommandBuffer(cb, &swapchain, image_index, pipeline);

        const image_acquire_si: vk.SemaphoreSubmitInfo = .{
            .semaphore = frame_resource.image_acquire_semaphore,
            .value = 0,
            .stage_mask = .{ .color_attachment_output_bit = true },
            .device_index = 0,
        };
        const semaphore_signals = [_]vk.SemaphoreSubmitInfo{
            .{
                .semaphore = render_semaphores[image_index],
                .value = 0,
                .stage_mask = .{ .all_graphics_bit = true },
                .device_index = 0,
            },
            .{
                .semaphore = timeline_semaphore,
                .value = signal_value,
                .stage_mask = .{ .all_commands_bit = true },
                .device_index = 0,
            },
        };
        const cb_submit_info: vk.CommandBufferSubmitInfo = .{
            .command_buffer = cb.handle,
            .device_mask = 0,
        };
        const submit_info: vk.SubmitInfo2 = .{
            .wait_semaphore_info_count = 1,
            .p_wait_semaphore_infos = @ptrCast(&image_acquire_si),
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast(&cb_submit_info),
            .signal_semaphore_info_count = semaphore_signals.len,
            .p_signal_semaphore_infos = &semaphore_signals,
        };
        try gfx_queue.submit2(@ptrCast(&submit_info), .null_handle);

        const present_info: vk.PresentInfoKHR = .{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&render_semaphores[image_index]),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&swapchain.handle),
            .p_image_indices = @ptrCast(&image_index),
        };
        const present_result = gfx_queue.presentKHR(&present_info) catch |err|
            switch (err) {
                error.OutOfDateKHR => {
                    recreate_swapchain = true;
                    continue;
                },
                else => return err,
            };

        if (present_result == .suboptimal_khr) {
            recreate_swapchain = true;
        }
    }

    try device.deviceWaitIdle();
}

fn createSwapchain(
    allocator: std.mem.Allocator,
    vma_allocator: vma.Allocator,
    instance: Instance,
    device: Device,
    physical_device: *const vkk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    depth_format: vk.Format,
    width: u32,
    height: u32,
    old_swapchain: vk.SwapchainKHR,
) !Swapchain {
    const swapchain = try vkk.Swapchain.create(
        allocator,
        instance,
        device,
        physical_device.handle,
        surface,
        .{
            .graphics_queue_family_index = physical_device.graphics_queue_family_index,
            .present_queue_family_index = physical_device.present_queue_family_index.?,
            .desired_extent = .{ .width = width, .height = height },
            .desired_formats = &.{.{ .format = .b8g8r8a8_srgb, .color_space = .srgb_nonlinear_khr }},
            .desired_present_modes = &.{.fifo_khr},
            .old_swapchain = old_swapchain,
        },
        null,
    );
    errdefer device.destroySwapchainKHR(swapchain.handle, null);

    const images = try device.getSwapchainImagesAllocKHR(swapchain.handle, allocator);
    errdefer allocator.free(images);

    const image_views = try swapchain.getImageViewsAlloc(allocator, device, images, null);
    errdefer {
        for (image_views) |view| {
            device.destroyImageView(view, null);
        }
        allocator.free(image_views);
    }

    var depth_image_ci: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .format = depth_format,
        .extent = .{ .width = swapchain.extent.width, .height = swapchain.extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .depth_stencil_attachment_bit = true },
        .initial_layout = .undefined,
        .sharing_mode = .exclusive,
    };
    const depth_image_alloc_ci: vma.AllocationCreateInfo = .{
        .flags = .{ .dedicated_memory_bit = true },
        .usage = .auto,
        .memory_type_bits = 0,
        .priority = 0,
        .min_alignment = 0,
    };
    const depth_image, const depth_image_allocation = try vma_allocator.createImage(
        &depth_image_ci,
        &depth_image_alloc_ci,
        null,
    );
    errdefer vma_allocator.destroyImage(depth_image, depth_image_allocation);

    var depth_view_ci: vk.ImageViewCreateInfo = .{
        .image = depth_image,
        .view_type = .@"2d",
        .format = depth_format,
        .subresource_range = .{
            .aspect_mask = .{ .depth_bit = true },
            .level_count = 1,
            .layer_count = 1,
            .base_array_layer = 0,
            .base_mip_level = 0,
        },
        .components = .{ .a = .identity, .r = .identity, .g = .identity, .b = .identity },
    };
    const depth_view = try device.createImageView(&depth_view_ci, null);
    errdefer device.destroyImageView(depth_view, null);

    return .{
        .handle = swapchain.handle,
        .image_count = swapchain.image_count,
        .width = swapchain.extent.width,
        .height = swapchain.extent.height,
        .image_format = swapchain.image_format,
        .images = images,
        .image_views = image_views,
        .depth_image = depth_image,
        .depth_image_allocation = depth_image_allocation,
        .depth_view = depth_view,
    };
}

fn recordCommandBuffer(
    cb: CommandBuffer,
    swapchain: *const Swapchain,
    image_index: u32,
    pipeline: vk.Pipeline,
) !void {
    const image = swapchain.images[image_index];
    const image_view = swapchain.image_views[image_index];

    const cb_begin_info: vk.CommandBufferBeginInfo = .{ .flags = .{ .one_time_submit_bit = true } };
    try cb.beginCommandBuffer(&cb_begin_info);

    const output_barriers = [_]vk.ImageMemoryBarrier2{
        .{
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{},
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_access_mask = .{ .color_attachment_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .attachment_optimal,
            .image = image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .level_count = 1,
                .layer_count = 1,
                .base_array_layer = 0,
                .base_mip_level = 0,
            },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        },
        .{
            .src_stage_mask = .{ .early_fragment_tests_bit = true },
            .src_access_mask = .{},
            .dst_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
            .dst_access_mask = .{ .depth_stencil_attachment_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .attachment_optimal,
            .image = swapchain.depth_image,
            .subresource_range = .{
                .aspect_mask = .{ .depth_bit = true },
                .level_count = 1,
                .layer_count = 1,
                .base_array_layer = 0,
                .base_mip_level = 0,
            },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        },
    };
    const barrier_dependency_info: vk.DependencyInfo = .{
        .image_memory_barrier_count = output_barriers.len,
        .p_image_memory_barriers = &output_barriers,
    };
    cb.pipelineBarrier2(&barrier_dependency_info);

    const color_attachement_info: vk.RenderingAttachmentInfo = .{
        .image_view = image_view,
        .image_layout = .attachment_optimal,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = .{ 0.01, 0.01, 0.01, 1.0 } } },
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
    };
    const depth_attachment_info: vk.RenderingAttachmentInfo = .{
        .image_view = swapchain.depth_view,
        .image_layout = .attachment_optimal,
        .load_op = .clear,
        .store_op = .dont_care,
        .clear_value = .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0.0 } },
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
    };
    const rendering_info: vk.RenderingInfo = .{
        .render_area = .{
            .extent = .{ .width = swapchain.width, .height = swapchain.height },
            .offset = .{ .x = 0, .y = 0 },
        },
        .layer_count = 1,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachement_info),
        .p_depth_attachment = &depth_attachment_info,
        .view_mask = 0,
    };
    cb.beginRendering(&rendering_info);

    const vp: vk.Viewport = .{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(swapchain.width),
        .height = @floatFromInt(swapchain.height),
        .min_depth = 0.0,
        .max_depth = 0.0,
    };
    cb.setViewport(0, @ptrCast(&vp));

    const scissor: vk.Rect2D = .{
        .extent = .{
            .width = swapchain.width,
            .height = swapchain.height,
        },
        .offset = .{ .x = 0, .y = 0 },
    };
    cb.setScissor(0, @ptrCast(&scissor));

    cb.bindPipeline(.graphics, pipeline);

    cb.draw(3, 1, 0, 0);

    cb.endRendering();

    const barrier_present: vk.ImageMemoryBarrier2 = .{
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{ .color_attachment_write_bit = true },
        .dst_stage_mask = .{},
        .dst_access_mask = .{},
        .old_layout = .color_attachment_optimal,
        .new_layout = .present_src_khr,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .level_count = 1,
            .layer_count = 1,
            .base_array_layer = 0,
            .base_mip_level = 0,
        },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
    };
    const present_dependency_info: vk.DependencyInfo = .{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&barrier_present),
    };
    cb.pipelineBarrier2(&present_dependency_info);

    try cb.endCommandBuffer();
}

fn createGraphicsPipeline(
    device: Device,
    vertex_shader: vk.ShaderModule,
    fragment_shader: vk.ShaderModule,
    pipeline_layout: vk.PipelineLayout,
    swapchain_format: vk.Format,
    depth_format: vk.Format,
) !vk.Pipeline {
    const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
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

    const vertex_input_ci: vk.PipelineVertexInputStateCreateInfo = .{};

    const input_assembly_ci: vk.PipelineInputAssemblyStateCreateInfo = .{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const depth_stencil_ci: vk.PipelineDepthStencilStateCreateInfo = .{
        .depth_test_enable = .true,
        .depth_write_enable = .true,
        .depth_compare_op = .less,
        .depth_bounds_test_enable = .false,
        .stencil_test_enable = .false,
        .front = .{
            .compare_mask = 0,
            .compare_op = .never,
            .depth_fail_op = .keep,
            .fail_op = .keep,
            .pass_op = .keep,
            .reference = 0,
            .write_mask = 0,
        },
        .back = .{
            .compare_mask = 0,
            .compare_op = .never,
            .depth_fail_op = .keep,
            .fail_op = .keep,
            .pass_op = .keep,
            .reference = 0,
            .write_mask = 0,
        },
        .min_depth_bounds = 0,
        .max_depth_bounds = 0,
    };

    const viewport_state_ci: vk.PipelineViewportStateCreateInfo = .{
        .viewport_count = 1,
        .scissor_count = 1,
    };

    const rasterizer_ci: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .line_width = 1.0,
        .cull_mode = .{ .back_bit = true },
        .front_face = .counter_clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_slope_factor = 0.0,
    };

    const multisample_ci: vk.PipelineMultisampleStateCreateInfo = .{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 0.0,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const color_blend_attachments = [_]vk.PipelineColorBlendAttachmentState{.{
        .blend_enable = .false,
        .src_color_blend_factor = .zero,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .zero,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    }};

    const color_blend_ci: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = color_blend_attachments.len,
        .p_attachments = &color_blend_attachments,
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic_state_ci: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    const rendering_ci: vk.PipelineRenderingCreateInfo = .{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&swapchain_format),
        .depth_attachment_format = depth_format,
        .stencil_attachment_format = .undefined,
    };

    const pipeline_ci: vk.GraphicsPipelineCreateInfo = .{
        .p_next = &rendering_ci,
        .stage_count = shader_stages.len,
        .p_stages = &shader_stages,
        .p_vertex_input_state = &vertex_input_ci,
        .p_input_assembly_state = &input_assembly_ci,
        .p_viewport_state = &viewport_state_ci,
        .p_rasterization_state = &rasterizer_ci,
        .p_multisample_state = &multisample_ci,
        .p_depth_stencil_state = &depth_stencil_ci,
        .p_color_blend_state = &color_blend_ci,
        .p_dynamic_state = &dynamic_state_ci,
        .layout = pipeline_layout,
        .subpass = 0,
        .base_pipeline_index = 0,
    };

    var graphics_pipeline: vk.Pipeline = .null_handle;
    const result = try device.createGraphicsPipelines(
        .null_handle,
        @ptrCast(&pipeline_ci),
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

fn createFrameResources(device: Device, queue_family_index: u32) ![max_frames_in_flight]FrameResource {
    var objects: [max_frames_in_flight]FrameResource = @splat(.empty);
    errdefer {
        for (objects) |object| {
            if (object.command_pool != .null_handle) {
                device.destroyCommandPool(object.command_pool, null);
            }
            if (object.image_acquire_semaphore != .null_handle) {
                device.destroySemaphore(object.image_acquire_semaphore, null);
            }
        }
    }

    const semaphore_info = vk.SemaphoreCreateInfo{};
    const command_pool_ci: vk.CommandPoolCreateInfo = .{ .queue_family_index = queue_family_index };
    for (0..objects.len) |i| {
        objects[i].command_pool = try device.createCommandPool(&command_pool_ci, null);

        const command_buffer_ai: vk.CommandBufferAllocateInfo = .{
            .command_buffer_count = 1,
            .command_pool = objects[i].command_pool,
            .level = .primary,
        };
        var command_buffer: vk.CommandBuffer = .null_handle;
        try device.allocateCommandBuffers(&command_buffer_ai, @ptrCast(&command_buffer));

        objects[i].command_buffer = .init(command_buffer, device.wrapper);
        objects[i].image_acquire_semaphore = try device.createSemaphore(&semaphore_info, null);
    }

    return objects;
}

fn destroyFrameResources(device: Device, objects: [max_frames_in_flight]FrameResource) void {
    for (objects) |object| {
        device.destroyCommandPool(object.command_pool, null);
        device.destroySemaphore(object.image_acquire_semaphore, null);
    }
}
