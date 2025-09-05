const std = @import("std");
const build_options = @import("build_options");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const PhysicalDevice = @import("PhysicalDevice.zig");
const Instance = vk.InstanceProxy;
const Device = vk.DeviceProxy;

const log = @import("log.zig").vk_kickstart_log;

const Error = error{
    OutOfMemory,
    CommandLoadFailure,
};

const CreateError = Error ||
    Allocator.Error ||
    Instance.CreateDeviceError;

pub fn create(
    allocator: Allocator,
    instance: Instance,
    physical_device: *const PhysicalDevice,
    p_next_chain: ?*anyopaque,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
) CreateError!Device {
    std.debug.assert(physical_device.handle != .null_handle);

    const queue_create_infos = try createQueueInfos(allocator, physical_device);
    defer allocator.free(queue_create_infos);

    var features = vk.PhysicalDeviceFeatures2{ .features = physical_device.features };
    var features_11 = physical_device.features_11;
    var features_12 = physical_device.features_12;
    var features_13 = physical_device.features_13;

    features.p_next = &features_11;
    if (physical_device.properties.api_version >= @as(u32, @bitCast(vk.API_VERSION_1_3))) {
        features_11.p_next = &features_12;
        features_12.p_next = &features_13;
        features_13.p_next = p_next_chain;
    } else if (physical_device.properties.api_version >= @as(u32, @bitCast(vk.API_VERSION_1_2))) {
        features_11.p_next = &features_12;
        features_12.p_next = p_next_chain;
    } else {
        features_11.p_next = p_next_chain;
    }

    const device_info = vk.DeviceCreateInfo{
        .queue_create_info_count = @intCast(queue_create_infos.len),
        .p_queue_create_infos = queue_create_infos.ptr,
        .enabled_extension_count = @intCast(physical_device.extensions.len),
        .pp_enabled_extension_names = physical_device.extensions.ptr,
        .p_next = &features,
    };

    const vkd = try allocator.create(vk.DeviceWrapper);
    errdefer allocator.destroy(vkd);

    const handle = try instance.createDevice(physical_device.handle, &device_info, allocation_callbacks);
    vkd.* = vk.DeviceWrapper.load(handle, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
    const device = Device.init(handle, vkd);
    errdefer device.destroyDevice(handle, allocation_callbacks);

    if (build_options.verbose) {
        log.debug("----- device creation -----", .{});
        log.debug("queue count: {d}", .{queue_create_infos.len});
        log.debug("graphics queue family index: {d}", .{physical_device.graphics_queue_index});
        log.debug("present queue family index: {d}", .{physical_device.present_queue_index});
        if (physical_device.transfer_queue_index) |family| {
            log.debug("transfer queue family index: {d}", .{family});
        }
        if (physical_device.compute_queue_index) |family| {
            log.debug("compute queue family index: {d}", .{family});
        }

        log.debug("enabled extensions:", .{});
        for (physical_device.extensions) |ext| {
            log.debug("- {s}", .{ext});
        }

        log.debug("enabled features:", .{});
        printEnabledFeatures(vk.PhysicalDeviceFeatures, features.features);
        log.debug("enabled features (vulkan 1.1):", .{});
        printEnabledFeatures(vk.PhysicalDeviceVulkan11Features, features_11);
        if (physical_device.properties.api_version >= @as(u32, @bitCast(vk.API_VERSION_1_2))) {
            log.debug("enabled features (vulkan 1.2):", .{});
            printEnabledFeatures(vk.PhysicalDeviceVulkan12Features, features_12);
        }
        if (physical_device.properties.api_version >= @as(u32, @bitCast(vk.API_VERSION_1_3))) {
            log.debug("enabled features (vulkan 1.3):", .{});
            printEnabledFeatures(vk.PhysicalDeviceVulkan13Features, features_13);
        }
    }

    return device;
}

fn printEnabledFeatures(comptime T: type, features: T) void {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("must be a struct");
    inline for (info.@"struct".fields) |field| {
        if (field.type == vk.Bool32 and @field(features, field.name) == .true) {
            log.debug(" - {s}", .{field.name});
        }
    }
}

fn createQueueInfos(
    allocator: Allocator,
    physical_device: *const PhysicalDevice,
) ![]vk.DeviceQueueCreateInfo {
    var unique_queue_families = std.AutoHashMap(u32, void).init(allocator);
    defer unique_queue_families.deinit();

    try unique_queue_families.put(physical_device.graphics_queue_index, {});
    try unique_queue_families.put(physical_device.present_queue_index, {});
    if (physical_device.transfer_queue_index) |idx| {
        try unique_queue_families.put(idx, {});
    }
    if (physical_device.compute_queue_index) |idx| {
        try unique_queue_families.put(idx, {});
    }

    var queue_create_infos: std.ArrayList(vk.DeviceQueueCreateInfo) = .empty;

    const queue_priorities = [_]f32{1};

    var it = unique_queue_families.iterator();
    while (it.next()) |queue_family| {
        const queue_create_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = queue_family.key_ptr.*,
            .queue_count = @intCast(queue_priorities.len),
            .p_queue_priorities = &queue_priorities,
        };
        try queue_create_infos.append(allocator, queue_create_info);
    }

    return try queue_create_infos.toOwnedSlice(allocator);
}
