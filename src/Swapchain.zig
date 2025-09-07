const std = @import("std");
const build_options = @import("build_options");
const vk = @import("vulkan");
const dispatch = @import("dispatch.zig");
const Swapchain = @This();
const root = @import("root");
const Allocator = std.mem.Allocator;
const Instance = vk.InstanceProxy;
const Device = vk.DeviceProxy;

const log = @import("log.zig").vk_kickstart_log;

const default_image_count = 3;

handle: vk.SwapchainKHR,
device: Device,
surface: vk.SurfaceKHR,
image_count: u32,
min_image_count: u32,
image_format: vk.Format,
image_usage: vk.ImageUsageFlags,
color_space: vk.ColorSpaceKHR,
extent: vk.Extent2D,
present_mode: vk.PresentModeKHR,

pub const CreateSettings = struct {
    /// Graphics queue index
    graphics_queue_index: u32,
    /// Present queue index
    present_queue_index: u32,
    /// Desired size (in pixels) of the swapchain image(s).
    /// These values will be clamped within the capabilities of the device
    desired_extent: vk.Extent2D,
    /// Swapchain create flags
    create_flags: vk.SwapchainCreateFlagsKHR = .{},
    /// Desired minimum number of presentable images that the application needs.
    /// If left on default, will try to use the minimum of the device + 1.
    /// This value will be clamped between the device's minimum and maximum (if there is a max).
    desired_min_image_count: ?u32 = null,
    /// Array of desired image formats, in order of priority.
    /// Will fallback to the first found if none match
    desired_formats: []const vk.SurfaceFormatKHR = &.{
        .{ .format = .b8g8r8a8_srgb, .color_space = .srgb_nonlinear_khr },
    },
    /// Array of desired present modes, in order of priority.
    /// Will fallback to fifo_khr is none match
    desired_present_modes: []const vk.PresentModeKHR = &.{
        .mailbox_khr,
    },
    /// Desired number of views in a multiview/stereo surface.
    /// Will be clamped down if higher than device's max
    desired_array_layer_count: u32 = 1,
    /// Intended usage of the (acquired) swapchain images
    image_usage_flags: vk.ImageUsageFlags = .{ .color_attachment_bit = true },
    /// Value describing the transform, relative to the presentation engine’s natural orientation, applied to the image content prior to presentation
    pre_transform: ?vk.SurfaceTransformFlagsKHR = null,
    /// Value indicating the alpha compositing mode to use when this surface is composited together with other surfaces on certain window systems
    composite_alpha: vk.CompositeAlphaFlagsKHR = .{ .opaque_bit_khr = true },
    /// Discard rendering operation that are not visible
    clipped: vk.Bool32 = .true,
    /// Existing non-retired swapchain currently associated with surface
    old_swapchain: ?vk.SwapchainKHR = null,
    /// pNext chain
    p_next_chain: ?*anyopaque = null,
};

const Error = error{
    Overflow,
    UsageFlagsNotSupported,
    GetPhysicalDeviceFormatsFailed,
    GetPhysicalDevicePresentModesFailed,
    GetSwapchainImageCountFailed,
};

pub const CreateError = Error ||
    Allocator.Error ||
    Instance.GetPhysicalDeviceSurfaceCapabilitiesKHRError ||
    Instance.GetPhysicalDeviceSurfaceFormatsKHRError ||
    Instance.GetPhysicalDeviceSurfacePresentModesKHRError ||
    Device.CreateSwapchainKHRError;

pub fn create(
    allocator: Allocator,
    instance: Instance,
    device: Device,
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    settings: CreateSettings,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
) CreateError!Swapchain {
    std.debug.assert(surface != .null_handle);
    std.debug.assert(physical_device != .null_handle);
    std.debug.assert(device.handle != .null_handle);

    const capabilities = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);

    const formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(physical_device, surface, allocator);
    defer allocator.free(formats);

    const present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(physical_device, surface, allocator);
    defer allocator.free(present_modes);

    const min_image_count = selectMinImageCount(&capabilities, settings.desired_min_image_count);
    const format = pickSurfaceFormat(formats, settings.desired_formats);
    const present_mode = pickPresentMode(present_modes, settings.desired_present_modes);
    const extent = pickExtent(&capabilities, settings.desired_extent);

    const array_layer_count = if (capabilities.max_image_array_layers < settings.desired_array_layer_count)
        capabilities.max_image_array_layers
    else
        settings.desired_array_layer_count;

    if (isSharedPresentMode(present_mode)) {
        // TODO: Shared present modes check
    } else {
        const supported_flags = capabilities.supported_usage_flags;
        if (settings.image_usage_flags.intersect(supported_flags).toInt() == 0)
            return error.UsageFlagsNotSupported;
    }

    const same_index = settings.graphics_queue_index == settings.present_queue_index;
    const queue_family_indices = [_]u32{ settings.graphics_queue_index, settings.present_queue_index };

    const swapchain_info = vk.SwapchainCreateInfoKHR{
        .p_next = settings.p_next_chain,
        .flags = settings.create_flags,
        .surface = surface,
        .min_image_count = min_image_count,
        .image_format = format.format,
        .image_color_space = format.color_space,
        .image_extent = extent,
        .image_array_layers = array_layer_count,
        .image_usage = settings.image_usage_flags,
        .image_sharing_mode = if (same_index) .exclusive else .concurrent,
        .queue_family_index_count = if (same_index) 0 else @intCast(queue_family_indices.len),
        .p_queue_family_indices = if (same_index) null else @ptrCast(&queue_family_indices),
        .pre_transform = if (settings.pre_transform) |pre_transform| pre_transform else capabilities.current_transform,
        .composite_alpha = settings.composite_alpha,
        .present_mode = present_mode,
        .clipped = settings.clipped,
        .old_swapchain = if (settings.old_swapchain) |old| old else .null_handle,
    };

    const swapchain = try device.createSwapchainKHR(&swapchain_info, allocation_callbacks);
    errdefer device.destroySwapchainKHR(swapchain, allocation_callbacks);

    var image_count: u32 = undefined;
    const result = try device.getSwapchainImagesKHR(swapchain, &image_count, null);
    if (result != .success) return error.GetSwapchainImageCountFailed;

    if (build_options.verbose) {
        log.debug("----- swapchain creation -----", .{});
        log.debug("image count: {d}", .{image_count});
        log.debug("image format: {s}", .{@tagName(format.format)});
        log.debug("color space: {s}", .{@tagName(format.color_space)});
        log.debug("present mode: {s}", .{@tagName(present_mode)});
        log.debug("extent: {d}x{d}", .{ extent.width, extent.height });
    }

    return .{
        .handle = swapchain,
        .device = device,
        .surface = surface,
        .min_image_count = min_image_count,
        .image_count = image_count,
        .image_format = format.format,
        .color_space = format.color_space,
        .extent = extent,
        .image_usage = settings.image_usage_flags,
        .present_mode = present_mode,
    };
}

pub const GetImagesError = error{GetSwapchainImagesFailed} || Device.GetSwapchainImagesKHRError;

/// Returns an array of the swapchain's images.
///
/// Buffer is used as the output.
pub fn getImages(self: *const Swapchain, buffer: []vk.Image) GetImagesError!void {
    var image_count: u32 = 0;
    var result = try self.device.getSwapchainImagesKHR(self.handle, &image_count, null);
    if (result != .success) return error.GetSwapchainImagesFailed;

    std.debug.assert(image_count == buffer.len);

    while (true) {
        result = try self.device.getSwapchainImagesKHR(self.handle, &image_count, buffer.ptr);
        if (result == .success) break;
    }
}

pub const GetImagesAllocError = Allocator.Error || GetImagesError;

/// Returns an array of the swapchain's images.
///
/// Caller owns the memory.
pub fn getImagesAlloc(self: *const Swapchain, allocator: std.mem.Allocator) GetImagesAllocError![]vk.Image {
    var image_count: u32 = 0;
    var result = try self.device.getSwapchainImagesKHR(self.handle, &image_count, null);
    if (result != .success) return error.GetSwapchainImagesFailed;

    const images = try allocator.alloc(vk.Image, image_count);
    errdefer allocator.free(images);

    while (true) {
        result = try self.device.getSwapchainImagesKHR(self.handle, &image_count, images.ptr);
        if (result == .success) break;
    }

    return images;
}

pub const GetImageViewsError = Device.CreateImageViewError;

/// Returns an array of image views to the images.
///
/// Buffer is used as the output.
pub fn getImageViews(
    self: *const Swapchain,
    images: []const vk.Image,
    buffer: []vk.ImageView,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
) GetImageViewsError!void {
    std.debug.assert(buffer.len == images.len);

    var initialized_count: u32 = 0;
    errdefer {
        for (0..initialized_count) |i| {
            self.device.destroyImageView(buffer[i], allocation_callbacks);
        }
    }

    for (images, 0..) |image, i| {
        const image_view_info = vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = self.image_format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        buffer[i] = try self.device.createImageView(&image_view_info, allocation_callbacks);
        initialized_count += 1;
    }
}

pub const GetImageViewsErrorAlloc = Allocator.Error || GetImageViewsError;

/// Returns an array of image views to the images.
///
/// Caller owns the memory.
pub fn getImageViewsAlloc(
    self: *const Swapchain,
    allocator: std.mem.Allocator,
    images: []const vk.Image,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
) GetImageViewsErrorAlloc![]vk.ImageView {
    const image_views = try allocator.alloc(vk.ImageView, images.len);

    var initialized_count: u32 = 0;
    errdefer {
        for (0..initialized_count) |i| {
            self.device.destroyImageView(image_views[i], allocation_callbacks);
        }
        allocator.free(image_views);
    }

    for (images, 0..) |image, i| {
        const image_view_info = vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = self.image_format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        image_views[i] = try self.device.createImageView(&image_view_info, allocation_callbacks);
        initialized_count += 1;
    }

    return image_views;
}

fn isSharedPresentMode(present_mode: vk.PresentModeKHR) bool {
    return !(present_mode == .immediate_khr or
        present_mode == .mailbox_khr or
        present_mode == .fifo_khr or
        present_mode == .fifo_relaxed_khr);
}

fn pickSurfaceFormat(
    available_formats: []const vk.SurfaceFormatKHR,
    desired_formats: []const vk.SurfaceFormatKHR,
) vk.SurfaceFormatKHR {
    for (desired_formats) |desired| {
        for (available_formats) |available| {
            if (available.format == desired.format and available.color_space == desired.color_space)
                return available;
        }
    }
    return available_formats[0];
}

fn pickPresentMode(
    available_modes: []const vk.PresentModeKHR,
    desired_modes: []const vk.PresentModeKHR,
) vk.PresentModeKHR {
    for (desired_modes) |desired| {
        for (available_modes) |available| {
            if (available == desired)
                return available;
        }
    }
    return .fifo_khr; // This mode is guaranteed to be present
}

fn pickExtent(
    surface_capabilities: *const vk.SurfaceCapabilitiesKHR,
    desired_extent: vk.Extent2D,
) vk.Extent2D {
    if (surface_capabilities.current_extent.width != std.math.maxInt(u32)) {
        return surface_capabilities.current_extent;
    }

    var actual_extent = desired_extent;

    actual_extent.width = std.math.clamp(
        actual_extent.width,
        surface_capabilities.min_image_extent.width,
        surface_capabilities.max_image_extent.width,
    );

    actual_extent.height = std.math.clamp(
        actual_extent.height,
        surface_capabilities.min_image_extent.height,
        surface_capabilities.max_image_extent.height,
    );

    return actual_extent;
}

fn selectMinImageCount(capabilities: *const vk.SurfaceCapabilitiesKHR, desired_min_image_count: ?u32) u32 {
    const has_max_count = capabilities.max_image_count > 0;
    const target_image_count = desired_min_image_count orelse default_image_count;
    var image_count = capabilities.min_image_count;
    if (target_image_count < capabilities.min_image_count)
        image_count = capabilities.min_image_count
    else if (has_max_count and target_image_count > capabilities.max_image_count)
        image_count = capabilities.max_image_count
    else
        image_count = target_image_count;

    return image_count;
}
