const std = @import("std");
const build_options = @import("build_options");
const vk = @import("vulkan");
const dispatch = @import("dispatch.zig");
const Instance = vk.InstanceProxy;
const root = @import("root");
const PhysicalDevice = @This();
const Allocator = std.mem.Allocator;

const log = @import("log.zig").vk_kickstart_log;

/// Max number of unique queues. At this time: graphics, present, compute and transfer.
pub const max_unique_queues = 4;

allocator: Allocator,
handle: vk.PhysicalDevice,
properties: vk.PhysicalDeviceProperties,
memory_properties: vk.PhysicalDeviceMemoryProperties,
features: vk.PhysicalDeviceFeatures,
features_11: vk.PhysicalDeviceVulkan11Features,
features_12: vk.PhysicalDeviceVulkan12Features,
features_13: vk.PhysicalDeviceVulkan13Features,
features_14: vk.PhysicalDeviceVulkan14Features,
extensions: [][*:0]const u8,
graphics_queue_index: u32,
present_queue_index: ?u32,
transfer_queue_index: ?u32,
compute_queue_index: ?u32,

pub const QueuePreference = enum {
    /// No queue will be created.
    none,
    /// Dedicated (for transfer -> without compute, for compute -> without transfer).
    /// Both will not be the same family as the graphics queue.
    dedicated,
    /// Separate from graphics family.
    /// This mode will try to find a dedicated, but will fallback to a common for
    /// transfer and compute if no dedicated is found.
    separate,
};

pub const SelectOptions = struct {
    /// Vulkan render surface.
    surface: vk.SurfaceKHR = .null_handle,
    /// Name of the device to select.
    name: ?[*:0]const u8 = null,
    /// Required Vulkan version (minimum 1.1).
    required_api_version: vk.Version = vk.API_VERSION_1_1,
    /// Prefered physical device type.
    preferred_type: vk.PhysicalDeviceType = .discrete_gpu,
    /// Transfer queue preference.
    transfer_queue: QueuePreference = .none,
    /// Compute queue preference.
    compute_queue: QueuePreference = .none,
    /// Required local memory size.
    required_mem_size: vk.DeviceSize = 0,
    /// Required physical device features.
    required_features: vk.PhysicalDeviceFeatures = .{},
    /// Required physical device feature version 1.1.
    required_features_11: vk.PhysicalDeviceVulkan11Features = .{},
    /// Required physical device feature version 1.2.
    required_features_12: ?vk.PhysicalDeviceVulkan12Features = null,
    /// Required physical device feature version 1.3.
    required_features_13: ?vk.PhysicalDeviceVulkan13Features = null,
    /// Required physical device feature version 1.4.
    required_features_14: ?vk.PhysicalDeviceVulkan14Features = null,
    /// Array of required physical device extensions to enable.
    /// Note: VK_KHR_portability_subset (if available) is automatically enabled.
    required_extensions: []const [*:0]const u8 = &.{},
};

const Error = error{
    Overflow,
    Features12UnsupportedByInstance,
    Features13UnsupportedByInstance,
    Features14UnsupportedByInstance,
    EnumeratePhysicalDevicesFailed,
    EnumeratePhysicalDeviceExtensionsFailed,
    NoSuitableDeviceFound,
};

pub const SelectError = Error ||
    Allocator.Error ||
    Instance.EnumeratePhysicalDevicesError ||
    Instance.EnumerateDeviceExtensionPropertiesError ||
    Instance.GetPhysicalDeviceSurfaceSupportKHRError ||
    Instance.GetPhysicalDeviceSurfaceFormatsKHRError;

pub fn select(
    allocator: Allocator,
    instance: Instance,
    options: SelectOptions,
) SelectError!PhysicalDevice {
    std.debug.assert(instance.handle != .null_handle);
    std.debug.assert(@as(u32, @bitCast(options.required_api_version)) >= @as(u32, @bitCast(vk.API_VERSION_1_1)));

    const physical_device_handles = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(physical_device_handles);

    const instance_version = try dispatch.vkb().enumerateInstanceVersion();
    var physical_device_infos: std.ArrayList(PhysicalDeviceInfo) = .empty;
    defer {
        for (physical_device_infos.items) |*info| {
            info.deinit(allocator);
        }
        physical_device_infos.deinit(allocator);
    }

    for (physical_device_handles) |handle| {
        const physical_device_info = try getPhysicalDeviceInfo(allocator, instance, handle, options.surface, instance_version);
        try physical_device_infos.append(allocator, physical_device_info);
    }

    for (physical_device_infos.items) |*info| {
        info.suitable = try isDeviceSuitable(instance, info, options.surface, options);
    }

    if (build_options.verbose) {
        log.debug("----- physical device selection -----", .{});
        log.debug("found {d} physical device{s}", .{
            physical_device_handles.len,
            if (physical_device_handles.len < 2) "" else "s",
        });

        for (physical_device_infos.items) |info| {
            const device_name: [*:0]const u8 = @ptrCast(&info.properties.device_name);
            log.debug("{s}", .{device_name});

            log.debug(" suitable: {s}", .{if (info.suitable) "yes" else "no"});
            const device_version: vk.Version = @bitCast(info.properties.api_version);
            log.debug(" api version: {d}.{d}.{d}", .{ device_version.major, device_version.minor, device_version.patch });
            log.debug(" device type: {s}", .{@tagName(info.properties.device_type)});
            const local_memory_size = getLocalMemorySize(&info.memory_properties);
            log.debug(" local memory size: {Bi:.2}", .{local_memory_size});

            log.debug(" queue family count: {d}", .{info.queue_families.len});
            log.debug(" graphics queue family: {s}", .{if (info.graphics_queue_index != null) "yes" else "no"});
            log.debug(" present queue family: {s}", .{if (info.present_queue_index != null) "yes" else "no"});
            log.debug(" dedicated transfer queue family: {s}", .{if (info.dedicated_transfer_queue_index != null) "yes" else "no"});
            log.debug(" dedicated compute queue family: {s}", .{if (info.dedicated_compute_queue_index != null) "yes" else "no"});
            log.debug(" separate transfer queue family: {s}", .{if (info.separate_transfer_queue_index != null) "yes" else "no"});
            log.debug(" separate compute queue family: {s}", .{if (info.separate_compute_queue_index != null) "yes" else "no"});

            log.debug(" portability extension available: {s}", .{if (info.portability_ext_available) "yes" else "no"});

            log.debug(" available extensions:", .{});
            for (info.available_extensions) |ext| {
                const ext_name: [*:0]const u8 = @ptrCast(&ext.extension_name);
                log.debug(" - {s}", .{ext_name});
            }

            log.debug(" available features:", .{});
            printAvailableFeatures(vk.PhysicalDeviceFeatures, info.features);
            log.debug(" available features (vulkan 1.1):", .{});
            printAvailableFeatures(vk.PhysicalDeviceVulkan11Features, info.features_11);
            if (info.properties.api_version >= @as(u32, @bitCast(vk.API_VERSION_1_2))) {
                log.debug(" available features (vulkan 1.2):", .{});
                printAvailableFeatures(vk.PhysicalDeviceVulkan12Features, info.features_12);
            }
            if (info.properties.api_version >= @as(u32, @bitCast(vk.API_VERSION_1_3))) {
                log.debug(" available features (vulkan 1.3):", .{});
                printAvailableFeatures(vk.PhysicalDeviceVulkan13Features, info.features_13);
            }
            if (info.properties.api_version >= @as(u32, @bitCast(vk.API_VERSION_1_4))) {
                log.debug(" available features (vulkan 1.4):", .{});
                printAvailableFeatures(vk.PhysicalDeviceVulkan14Features, info.features_14);
            }
        }
    }

    std.sort.insertion(PhysicalDeviceInfo, physical_device_infos.items, options, comparePhysicalDevices);

    const selected = &physical_device_infos.items[0];
    if (!selected.suitable) return error.NoSuitableDeviceFound;

    var extensions: std.ArrayList([*:0]const u8) = .empty;

    for (options.required_extensions) |ext| {
        try extensions.append(allocator, ext);
    }

    if (selected.portability_ext_available) {
        try extensions.append(allocator, vk.extensions.khr_portability_subset.name);
    }

    if (build_options.verbose) {
        const device_name: [*:0]const u8 = @ptrCast(&selected.properties.device_name);
        log.debug("selected {s}", .{device_name});
    }

    return .{
        .allocator = allocator,
        .handle = selected.handle,
        .features = options.required_features,
        .features_11 = options.required_features_11,
        .features_12 = if (options.required_features_12) |features| features else .{},
        .features_13 = if (options.required_features_13) |features| features else .{},
        .features_14 = if (options.required_features_14) |features| features else .{},
        .properties = selected.properties,
        .memory_properties = selected.memory_properties,
        .extensions = try extensions.toOwnedSlice(allocator),
        .graphics_queue_index = selected.graphics_queue_index.?,
        .present_queue_index = selected.present_queue_index,
        .transfer_queue_index = switch (options.transfer_queue) {
            .none => null,
            .dedicated => selected.dedicated_transfer_queue_index,
            .separate => selected.separate_transfer_queue_index,
        },
        .compute_queue_index = switch (options.compute_queue) {
            .none => null,
            .dedicated => selected.dedicated_compute_queue_index,
            .separate => selected.separate_compute_queue_index,
        },
    };
}

pub fn deinit(self: *const PhysicalDevice) void {
    self.allocator.free(self.extensions);
}

/// Returns the physical device's name.
pub fn name(self: *const PhysicalDevice) []const u8 {
    const str: [*:0]const u8 = @ptrCast(&self.properties.device_name);
    return std.mem.span(str);
}

fn printAvailableFeatures(comptime T: type, features: T) void {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("must be a struct");
    inline for (info.@"struct".fields) |field| {
        if (field.type == vk.Bool32) {
            log.debug(" - {s}: {s}", .{ field.name, if (@field(features, field.name) != .false) "yes" else "no" });
        }
    }
}

const PhysicalDeviceInfo = struct {
    handle: vk.PhysicalDevice,
    features: vk.PhysicalDeviceFeatures,
    features_11: vk.PhysicalDeviceVulkan11Features,
    features_12: vk.PhysicalDeviceVulkan12Features,
    features_13: vk.PhysicalDeviceVulkan13Features,
    features_14: vk.PhysicalDeviceVulkan14Features,
    properties: vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    available_extensions: []vk.ExtensionProperties,
    queue_families: []vk.QueueFamilyProperties,
    graphics_queue_index: ?u32,
    present_queue_index: ?u32,
    dedicated_transfer_queue_index: ?u32,
    dedicated_compute_queue_index: ?u32,
    separate_transfer_queue_index: ?u32,
    separate_compute_queue_index: ?u32,
    portability_ext_available: bool,
    suitable: bool = true,

    fn deinit(self: *PhysicalDeviceInfo, allocator: Allocator) void {
        allocator.free(self.available_extensions);
        allocator.free(self.queue_families);
    }
};

fn getPresentQueue(
    instance: Instance,
    handle: vk.PhysicalDevice,
    families: []const vk.QueueFamilyProperties,
    surface: vk.SurfaceKHR,
) !?u32 {
    for (families, 0..) |family, i| {
        if (family.queue_count == 0) continue;

        const idx: u32 = @intCast(i);

        if (try instance.getPhysicalDeviceSurfaceSupportKHR(handle, idx, surface) == .true) {
            return idx;
        }
    }
    return null;
}

fn getQueueStrict(
    families: []const vk.QueueFamilyProperties,
    wanted_flags: vk.QueueFlags,
    unwanted_flags: vk.QueueFlags,
) ?u32 {
    for (families, 0..) |family, i| {
        if (family.queue_count == 0) continue;

        const idx: u32 = @intCast(i);

        const has_wanted = family.queue_flags.contains(wanted_flags);
        const no_unwanted = family.queue_flags.intersect(unwanted_flags).toInt() == vk.QueueFlags.toInt(.{});
        if (has_wanted and no_unwanted) {
            return idx;
        }
    }
    return null;
}

fn getQueueNoGraphics(
    families: []const vk.QueueFamilyProperties,
    wanted_flags: vk.QueueFlags,
    unwanted_flags: vk.QueueFlags,
) ?u32 {
    var index: ?u32 = null;
    for (families, 0..) |family, i| {
        if (family.queue_count == 0 or family.queue_flags.graphics_bit) continue;

        const idx: u32 = @intCast(i);

        const has_wanted = family.queue_flags.contains(wanted_flags);
        const no_unwanted = family.queue_flags.intersect(unwanted_flags).toInt() == vk.QueueFlags.toInt(.{});
        if (has_wanted) {
            if (no_unwanted) return idx;
            if (index == null) index = idx;
        }
    }
    return index;
}

fn comparePhysicalDevices(options: SelectOptions, a: PhysicalDeviceInfo, b: PhysicalDeviceInfo) bool {
    if (a.suitable != b.suitable) {
        return a.suitable;
    }

    const a_is_prefered_type = a.properties.device_type == options.preferred_type;
    const b_is_prefered_type = b.properties.device_type == options.preferred_type;
    if (a_is_prefered_type != b_is_prefered_type) {
        return a_is_prefered_type;
    }

    const local_memory_a = getLocalMemorySize(&a.memory_properties);
    const local_memory_b = getLocalMemorySize(&b.memory_properties);
    if (local_memory_a != local_memory_b) {
        return local_memory_a >= local_memory_b;
    }

    if (a.properties.api_version != b.properties.api_version) {
        return a.properties.api_version >= b.properties.api_version;
    }

    return true;
}

fn getLocalMemorySize(memory_properties: *const vk.PhysicalDeviceMemoryProperties) vk.DeviceSize {
    var size: vk.DeviceSize = 0;
    const heap_count = memory_properties.memory_heap_count;
    for (memory_properties.memory_heaps[0..heap_count]) |heap| {
        if (heap.flags.device_local_bit) {
            // NOTE: take the sum instead to account for small local fast heap?
            size = @max(size, heap.size);
        }
    }

    return size;
}

fn isDeviceSuitable(
    instance: Instance,
    device: *const PhysicalDeviceInfo,
    surface: vk.SurfaceKHR,
    options: SelectOptions,
) !bool {
    if (options.name) |n| {
        const device_name: [*:0]const u8 = @ptrCast(&device.properties.device_name);
        if (std.mem.orderZ(u8, n, device_name) != .eq) return false;
    }

    const required_version: u32 = @bitCast(options.required_api_version);
    const device_version: u32 = @bitCast(device.properties.api_version);
    if (device_version < required_version) return false;

    if (options.transfer_queue == .dedicated and device.dedicated_transfer_queue_index == null) return false;
    if (options.transfer_queue == .separate and device.separate_transfer_queue_index == null) return false;
    if (options.compute_queue == .dedicated and device.dedicated_compute_queue_index == null) return false;
    if (options.compute_queue == .separate and device.separate_compute_queue_index == null) return false;

    if (!supportsRequiredFeatures(device.features, options.required_features)) return false;
    if (!supportsRequiredFeatures11(device.features_11, options.required_features_11)) return false;
    if (!supportsRequiredFeatures12(device.features_12, options.required_features_12)) return false;
    if (!supportsRequiredFeatures13(device.features_13, options.required_features_13)) return false;
    if (!supportsRequiredFeatures14(device.features_14, options.required_features_14)) return false;

    for (options.required_extensions) |ext| {
        if (!isExtensionAvailable(device.available_extensions, ext)) {
            return false;
        }
    }

    if (device.graphics_queue_index == null or device.present_queue_index == null) return false;
    if (!isExtensionAvailable(device.available_extensions, vk.extensions.khr_swapchain.name)) {
        return false;
    }

    if (surface != .null_handle) {
        if (!try isCompatibleWithSurface(instance, device.handle, surface)) {
            return false;
        }
    }

    const heap_count = device.memory_properties.memory_heap_count;
    for (device.memory_properties.memory_heaps[0..heap_count]) |heap| {
        if (heap.flags.device_local_bit and heap.size >= options.required_mem_size) {
            break;
        }
    } else {
        return false;
    }

    return true;
}

fn isCompatibleWithSurface(instance: Instance, handle: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = 0;
    var result = try instance.getPhysicalDeviceSurfaceFormatsKHR(handle, surface, &format_count, null);
    if (result != .success) return false;

    var present_mode_count: u32 = 0;
    result = try instance.getPhysicalDeviceSurfacePresentModesKHR(handle, surface, &present_mode_count, null);
    if (result != .success) return false;

    return format_count > 0 and present_mode_count > 0;
}

fn isExtensionAvailable(
    available_extensions: []const vk.ExtensionProperties,
    extension: [*:0]const u8,
) bool {
    for (available_extensions) |ext| {
        const n: [*:0]const u8 = @ptrCast(&ext.extension_name);
        if (std.mem.orderZ(u8, n, extension) == .eq) {
            return true;
        }
    }
    return false;
}

fn getPhysicalDeviceInfo(
    allocator: Allocator,
    instance: Instance,
    handle: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    api_version: u32,
) !PhysicalDeviceInfo {
    const properties = instance.getPhysicalDeviceProperties(handle);
    const memory_properties = instance.getPhysicalDeviceMemoryProperties(handle);

    var features = vk.PhysicalDeviceFeatures2{ .features = .{} };
    var features_11 = vk.PhysicalDeviceVulkan11Features{};
    var features_12 = vk.PhysicalDeviceVulkan12Features{};
    var features_13 = vk.PhysicalDeviceVulkan13Features{};
    var features_14 = vk.PhysicalDeviceVulkan14Features{};

    features.p_next = &features_11;
    if (api_version >= @as(u32, @bitCast(vk.API_VERSION_1_2)))
        features_11.p_next = &features_12;
    if (api_version >= @as(u32, @bitCast(vk.API_VERSION_1_3)))
        features_12.p_next = &features_13;
    if (api_version >= @as(u32, @bitCast(vk.API_VERSION_1_4)))
        features_13.p_next = &features_14;

    instance.getPhysicalDeviceFeatures2(handle, &features);

    const available_extensions = try instance.enumerateDeviceExtensionPropertiesAlloc(handle, null, allocator);
    errdefer allocator.free(available_extensions);
    const queue_families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(handle, allocator);
    errdefer allocator.free(queue_families);

    const graphics_queue_index = getQueueStrict(queue_families, .{ .graphics_bit = true }, .{});
    const dedicated_transfer = getQueueStrict(
        queue_families,
        .{ .transfer_bit = true },
        .{ .graphics_bit = true, .compute_bit = true },
    );
    const dedicated_compute = getQueueStrict(
        queue_families,
        .{ .compute_bit = true },
        .{ .graphics_bit = true, .transfer_bit = true },
    );
    const separate_transfer = getQueueNoGraphics(
        queue_families,
        .{ .transfer_bit = true },
        .{ .compute_bit = true },
    );
    const separate_compute = getQueueNoGraphics(
        queue_families,
        .{ .compute_bit = true },
        .{ .transfer_bit = true },
    );
    const present_queue_index = switch (surface) {
        .null_handle => null,
        else => try getPresentQueue(instance, handle, queue_families, surface),
    };

    const portability_ext_available = isExtensionAvailable(available_extensions, vk.extensions.khr_portability_subset.name);

    return .{
        .handle = handle,
        .features = features.features,
        .features_11 = features_11,
        .features_12 = features_12,
        .features_13 = features_13,
        .features_14 = features_14,
        .properties = properties,
        .memory_properties = memory_properties,
        .available_extensions = available_extensions,
        .queue_families = queue_families,
        .graphics_queue_index = graphics_queue_index,
        .present_queue_index = present_queue_index,
        .dedicated_transfer_queue_index = dedicated_transfer,
        .dedicated_compute_queue_index = dedicated_compute,
        .separate_transfer_queue_index = separate_transfer,
        .separate_compute_queue_index = separate_compute,
        .portability_ext_available = portability_ext_available,
    };
}

fn supportsRequiredFeatures(available: vk.PhysicalDeviceFeatures, required: vk.PhysicalDeviceFeatures) bool {
    if (required.alpha_to_one == .true and available.alpha_to_one == .false) return false;
    if (required.depth_bias_clamp == .true and available.depth_bias_clamp == .false) return false;
    if (required.depth_bounds == .true and available.depth_bounds == .false) return false;
    if (required.depth_clamp == .true and available.depth_clamp == .false) return false;
    if (required.draw_indirect_first_instance == .true and available.draw_indirect_first_instance == .false) return false;
    if (required.dual_src_blend == .true and available.dual_src_blend == .false) return false;
    if (required.fill_mode_non_solid == .true and available.fill_mode_non_solid == .false) return false;
    if (required.fragment_stores_and_atomics == .true and available.fragment_stores_and_atomics == .false) return false;
    if (required.full_draw_index_uint_32 == .true and available.full_draw_index_uint_32 == .false) return false;
    if (required.geometry_shader == .true and available.geometry_shader == .false) return false;
    if (required.image_cube_array == .true and available.image_cube_array == .false) return false;
    if (required.independent_blend == .true and available.independent_blend == .false) return false;
    if (required.inherited_queries == .true and available.inherited_queries == .false) return false;
    if (required.large_points == .true and available.large_points == .false) return false;
    if (required.logic_op == .true and available.logic_op == .false) return false;
    if (required.multi_draw_indirect == .true and available.multi_draw_indirect == .false) return false;
    if (required.multi_viewport == .true and available.multi_viewport == .false) return false;
    if (required.occlusion_query_precise == .true and available.occlusion_query_precise == .false) return false;
    if (required.pipeline_statistics_query == .true and available.pipeline_statistics_query == .false) return false;
    if (required.robust_buffer_access == .true and available.robust_buffer_access == .false) return false;
    if (required.sample_rate_shading == .true and available.sample_rate_shading == .false) return false;
    if (required.sampler_anisotropy == .true and available.sampler_anisotropy == .false) return false;
    if (required.shader_clip_distance == .true and available.shader_clip_distance == .false) return false;
    if (required.shader_cull_distance == .true and available.shader_cull_distance == .false) return false;
    if (required.shader_float_64 == .true and available.shader_float_64 == .false) return false;
    if (required.shader_image_gather_extended == .true and available.shader_image_gather_extended == .false) return false;
    if (required.shader_int_16 == .true and available.shader_int_16 == .false) return false;
    if (required.shader_int_64 == .true and available.shader_int_64 == .false) return false;
    if (required.shader_resource_min_lod == .true and available.shader_resource_min_lod == .false) return false;
    if (required.shader_resource_residency == .true and available.shader_resource_residency == .false) return false;
    if (required.shader_tessellation_and_geometry_point_size == .true and available.shader_tessellation_and_geometry_point_size == .false) return false;
    if (required.shader_sampled_image_array_dynamic_indexing == .true and available.shader_sampled_image_array_dynamic_indexing == .false) return false;
    if (required.shader_storage_buffer_array_dynamic_indexing == .true and available.shader_storage_buffer_array_dynamic_indexing == .false) return false;
    if (required.shader_storage_image_array_dynamic_indexing == .true and available.shader_storage_image_array_dynamic_indexing == .false) return false;
    if (required.shader_storage_image_extended_formats == .true and available.shader_storage_image_extended_formats == .false) return false;
    if (required.shader_storage_image_multisample == .true and available.shader_storage_image_multisample == .false) return false;
    if (required.shader_storage_image_read_without_format == .true and available.shader_storage_image_read_without_format == .false) return false;
    if (required.shader_storage_image_write_without_format == .true and available.shader_storage_image_write_without_format == .false) return false;
    if (required.shader_uniform_buffer_array_dynamic_indexing == .true and available.shader_uniform_buffer_array_dynamic_indexing == .false) return false;
    if (required.sparse_binding == .true and available.sparse_binding == .false) return false;
    if (required.sparse_residency_2_samples == .true and available.sparse_residency_2_samples == .false) return false;
    if (required.sparse_residency_4_samples == .true and available.sparse_residency_4_samples == .false) return false;
    if (required.sparse_residency_8_samples == .true and available.sparse_residency_8_samples == .false) return false;
    if (required.sparse_residency_16_samples == .true and available.sparse_residency_16_samples == .false) return false;
    if (required.sparse_residency_aliased == .true and available.sparse_residency_aliased == .false) return false;
    if (required.sparse_residency_buffer == .true and available.sparse_residency_buffer == .false) return false;
    if (required.sparse_residency_image_2d == .true and available.sparse_residency_image_2d == .false) return false;
    if (required.sparse_residency_image_3d == .true and available.sparse_residency_image_3d == .false) return false;
    if (required.tessellation_shader == .true and available.tessellation_shader == .false) return false;
    if (required.texture_compression_astc_ldr == .true and available.texture_compression_astc_ldr == .false) return false;
    if (required.texture_compression_bc == .true and available.texture_compression_bc == .false) return false;
    if (required.texture_compression_etc2 == .true and available.texture_compression_etc2 == .false) return false;
    if (required.variable_multisample_rate == .true and available.variable_multisample_rate == .false) return false;
    if (required.vertex_pipeline_stores_and_atomics == .true and available.vertex_pipeline_stores_and_atomics == .false) return false;
    if (required.wide_lines == .true and available.wide_lines == .false) return false;

    return true;
}

fn supportsRequiredFeatures11(available: vk.PhysicalDeviceVulkan11Features, required: vk.PhysicalDeviceVulkan11Features) bool {
    if (required.storage_buffer_16_bit_access == .true and available.storage_buffer_16_bit_access == .false) return false;
    if (required.uniform_and_storage_buffer_16_bit_access == .true and available.uniform_and_storage_buffer_16_bit_access == .false) return false;
    if (required.storage_push_constant_16 == .true and available.storage_push_constant_16 == .false) return false;
    if (required.storage_input_output_16 == .true and available.storage_input_output_16 == .false) return false;
    if (required.multiview == .true and available.multiview == .false) return false;
    if (required.multiview_geometry_shader == .true and available.multiview_geometry_shader == .false) return false;
    if (required.multiview_tessellation_shader == .true and available.multiview_tessellation_shader == .false) return false;
    if (required.variable_pointers_storage_buffer == .true and available.variable_pointers_storage_buffer == .false) return false;
    if (required.variable_pointers == .true and available.variable_pointers == .false) return false;
    if (required.protected_memory == .true and available.protected_memory == .false) return false;
    if (required.sampler_ycbcr_conversion == .true and available.sampler_ycbcr_conversion == .false) return false;
    if (required.shader_draw_parameters == .true and available.shader_draw_parameters == .false) return false;

    return true;
}

fn supportsRequiredFeatures12(available: vk.PhysicalDeviceVulkan12Features, required: ?vk.PhysicalDeviceVulkan12Features) bool {
    if (required == null) return true;

    const req = required.?;
    if (req.sampler_mirror_clamp_to_edge == .true and available.sampler_mirror_clamp_to_edge == .false) return false;
    if (req.draw_indirect_count == .true and available.draw_indirect_count == .false) return false;
    if (req.storage_buffer_8_bit_access == .true and available.storage_buffer_8_bit_access == .false) return false;
    if (req.uniform_and_storage_buffer_8_bit_access == .true and available.uniform_and_storage_buffer_8_bit_access == .false) return false;
    if (req.storage_push_constant_8 == .true and available.storage_push_constant_8 == .false) return false;
    if (req.shader_buffer_int_64_atomics == .true and available.shader_buffer_int_64_atomics == .false) return false;
    if (req.shader_shared_int_64_atomics == .true and available.shader_shared_int_64_atomics == .false) return false;
    if (req.shader_float_16 == .true and available.shader_float_16 == .false) return false;
    if (req.shader_int_8 == .true and available.shader_int_8 == .false) return false;
    if (req.descriptor_indexing == .true and available.descriptor_indexing == .false) return false;
    if (req.shader_input_attachment_array_dynamic_indexing == .true and available.shader_input_attachment_array_dynamic_indexing == .false) return false;
    if (req.shader_uniform_texel_buffer_array_dynamic_indexing == .true and available.shader_uniform_texel_buffer_array_dynamic_indexing == .false) return false;
    if (req.shader_storage_texel_buffer_array_dynamic_indexing == .true and available.shader_storage_texel_buffer_array_dynamic_indexing == .false) return false;
    if (req.shader_uniform_buffer_array_non_uniform_indexing == .true and available.shader_uniform_buffer_array_non_uniform_indexing == .false) return false;
    if (req.shader_sampled_image_array_non_uniform_indexing == .true and available.shader_sampled_image_array_non_uniform_indexing == .false) return false;
    if (req.shader_storage_buffer_array_non_uniform_indexing == .true and available.shader_storage_buffer_array_non_uniform_indexing == .false) return false;
    if (req.shader_storage_image_array_non_uniform_indexing == .true and available.shader_storage_image_array_non_uniform_indexing == .false) return false;
    if (req.shader_input_attachment_array_non_uniform_indexing == .true and available.shader_input_attachment_array_non_uniform_indexing == .false) return false;
    if (req.shader_uniform_texel_buffer_array_non_uniform_indexing == .true and available.shader_uniform_texel_buffer_array_non_uniform_indexing == .false) return false;
    if (req.shader_storage_texel_buffer_array_non_uniform_indexing == .true and available.shader_storage_texel_buffer_array_non_uniform_indexing == .false) return false;
    if (req.descriptor_binding_uniform_buffer_update_after_bind == .true and available.descriptor_binding_uniform_buffer_update_after_bind == .false) return false;
    if (req.descriptor_binding_sampled_image_update_after_bind == .true and available.descriptor_binding_sampled_image_update_after_bind == .false) return false;
    if (req.descriptor_binding_storage_image_update_after_bind == .true and available.descriptor_binding_storage_image_update_after_bind == .false) return false;
    if (req.descriptor_binding_storage_buffer_update_after_bind == .true and available.descriptor_binding_storage_buffer_update_after_bind == .false) return false;
    if (req.descriptor_binding_uniform_texel_buffer_update_after_bind == .true and available.descriptor_binding_uniform_texel_buffer_update_after_bind == .false) return false;
    if (req.descriptor_binding_storage_texel_buffer_update_after_bind == .true and available.descriptor_binding_storage_texel_buffer_update_after_bind == .false) return false;
    if (req.descriptor_binding_update_unused_while_pending == .true and available.descriptor_binding_update_unused_while_pending == .false) return false;
    if (req.descriptor_binding_partially_bound == .true and available.descriptor_binding_partially_bound == .false) return false;
    if (req.descriptor_binding_variable_descriptor_count == .true and available.descriptor_binding_variable_descriptor_count == .false) return false;
    if (req.runtime_descriptor_array == .true and available.runtime_descriptor_array == .false) return false;
    if (req.sampler_filter_minmax == .true and available.sampler_filter_minmax == .false) return false;
    if (req.scalar_block_layout == .true and available.scalar_block_layout == .false) return false;
    if (req.imageless_framebuffer == .true and available.imageless_framebuffer == .false) return false;
    if (req.uniform_buffer_standard_layout == .true and available.uniform_buffer_standard_layout == .false) return false;
    if (req.shader_subgroup_extended_types == .true and available.shader_subgroup_extended_types == .false) return false;
    if (req.separate_depth_stencil_layouts == .true and available.separate_depth_stencil_layouts == .false) return false;
    if (req.host_query_reset == .true and available.host_query_reset == .false) return false;
    if (req.timeline_semaphore == .true and available.timeline_semaphore == .false) return false;
    if (req.buffer_device_address == .true and available.buffer_device_address == .false) return false;
    if (req.buffer_device_address_capture_replay == .true and available.buffer_device_address_capture_replay == .false) return false;
    if (req.buffer_device_address_multi_device == .true and available.buffer_device_address_multi_device == .false) return false;
    if (req.vulkan_memory_model == .true and available.vulkan_memory_model == .false) return false;
    if (req.vulkan_memory_model_device_scope == .true and available.vulkan_memory_model_device_scope == .false) return false;
    if (req.vulkan_memory_model_availability_visibility_chains == .true and available.vulkan_memory_model_availability_visibility_chains == .false) return false;
    if (req.shader_output_viewport_index == .true and available.shader_output_viewport_index == .false) return false;
    if (req.shader_output_layer == .true and available.shader_output_layer == .false) return false;
    if (req.subgroup_broadcast_dynamic_id == .true and available.subgroup_broadcast_dynamic_id == .false) return false;

    return true;
}

fn supportsRequiredFeatures13(available: vk.PhysicalDeviceVulkan13Features, required: ?vk.PhysicalDeviceVulkan13Features) bool {
    if (required == null) return true;

    const req = required.?;
    if (req.robust_image_access == .true and available.robust_image_access == .false) return false;
    if (req.inline_uniform_block == .true and available.inline_uniform_block == .false) return false;
    if (req.descriptor_binding_inline_uniform_block_update_after_bind == .true and available.descriptor_binding_inline_uniform_block_update_after_bind == .false) return false;
    if (req.pipeline_creation_cache_control == .true and available.pipeline_creation_cache_control == .false) return false;
    if (req.private_data == .true and available.private_data == .false) return false;
    if (req.shader_demote_to_helper_invocation == .true and available.shader_demote_to_helper_invocation == .false) return false;
    if (req.shader_terminate_invocation == .true and available.shader_terminate_invocation == .false) return false;
    if (req.subgroup_size_control == .true and available.subgroup_size_control == .false) return false;
    if (req.compute_full_subgroups == .true and available.compute_full_subgroups == .false) return false;
    if (req.synchronization_2 == .true and available.synchronization_2 == .false) return false;
    if (req.texture_compression_astc_hdr == .true and available.texture_compression_astc_hdr == .false) return false;
    if (req.shader_zero_initialize_workgroup_memory == .true and available.shader_zero_initialize_workgroup_memory == .false) return false;
    if (req.dynamic_rendering == .true and available.dynamic_rendering == .false) return false;
    if (req.shader_integer_dot_product == .true and available.shader_integer_dot_product == .false) return false;
    if (req.maintenance_4 == .true and available.maintenance_4 == .false) return false;
    return true;
}

fn supportsRequiredFeatures14(available: vk.PhysicalDeviceVulkan14Features, required: ?vk.PhysicalDeviceVulkan14Features) bool {
    if (required == null) return true;

    const req = required.?;
    if (req.global_priority_query == .true and available.global_priority_query == .false) return false;
    if (req.shader_subgroup_rotate == .true and available.shader_subgroup_rotate == .false) return false;
    if (req.shader_subgroup_rotate_clustered == .true and available.shader_subgroup_rotate_clustered == .false) return false;
    if (req.shader_float_controls_2 == .true and available.shader_float_controls_2 == .false) return false;
    if (req.shader_expect_assume == .true and available.shader_expect_assume == .false) return false;
    if (req.rectangular_lines == .true and available.rectangular_lines == .false) return false;
    if (req.bresenham_lines == .true and available.bresenham_lines == .false) return false;
    if (req.smooth_lines == .true and available.smooth_lines == .false) return false;
    if (req.stippled_rectangular_lines == .true and available.stippled_rectangular_lines == .false) return false;
    if (req.stippled_bresenham_lines == .true and available.stippled_bresenham_lines == .false) return false;
    if (req.stippled_smooth_lines == .true and available.stippled_smooth_lines == .false) return false;
    if (req.vertex_attribute_instance_rate_divisor == .true and available.vertex_attribute_instance_rate_divisor == .false) return false;
    if (req.vertex_attribute_instance_rate_zero_divisor == .true and available.vertex_attribute_instance_rate_zero_divisor == .false) return false;
    if (req.index_type_uint_8 == .true and available.index_type_uint_8 == .false) return false;
    if (req.dynamic_rendering_local_read == .true and available.dynamic_rendering_local_read == .false) return false;
    if (req.maintenance_5 == .true and available.maintenance_5 == .false) return false;
    if (req.maintenance_6 == .true and available.maintenance_6 == .false) return false;
    if (req.pipeline_protected_access == .true and available.pipeline_protected_access == .false) return false;
    if (req.pipeline_robustness == .true and available.pipeline_robustness == .false) return false;
    if (req.host_image_copy == .true and available.host_image_copy == .false) return false;
    if (req.push_descriptor == .true and available.push_descriptor == .false) return false;
    return true;
}
