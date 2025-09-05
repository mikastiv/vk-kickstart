const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const build_options = @import("build_options");
const root = @import("root");
const dispatch = @import("dispatch.zig");
const Allocator = std.mem.Allocator;
const Instance = vk.InstanceProxy;

const log = @import("log.zig").vk_kickstart_log;
const vk_log = @import("log.zig").vulkan_log;

const validation_layers: []const [*:0]const u8 = &.{"VK_LAYER_KHRONOS_validation"};

const default_message_severity: vk.DebugUtilsMessageSeverityFlagsEXT = .{
    .warning_bit_ext = true,
    .error_bit_ext = true,
};
const default_message_type: vk.DebugUtilsMessageTypeFlagsEXT = .{
    .general_bit_ext = true,
    .validation_bit_ext = true,
    .performance_bit_ext = true,
};

pub const CreateOptions = struct {
    /// Application name.
    app_name: [*:0]const u8 = "",
    /// Application version.
    app_version: vk.Version = vk.makeApiVersion(0, 0, 0, 0),
    /// Engine name.
    engine_name: [*:0]const u8 = "",
    /// Engine version.
    engine_version: vk.Version = vk.makeApiVersion(0, 0, 0, 0),
    /// Required Vulkan version (minimum 1.1).
    required_api_version: vk.Version = vk.API_VERSION_1_1,
    /// Array of required extensions to enable.
    /// Note: VK_KHR_surface and the platform specific surface extension are automatically enabled.
    required_extensions: []const [*:0]const u8 = &.{},
    /// Array of required layers to enable.
    required_layers: []const [*:0]const u8 = &.{},
    /// pNext chain.
    p_next_chain: ?*anyopaque = null,
    /// Debug messenger options
    debug: DebugMessengerOptions = .{},
};

pub const DebugMessengerOptions = struct {
    /// Custom debug callback function (or use default).
    callback: vk.PfnDebugUtilsMessengerCallbackEXT = defaultDebugMessageCallback,
    /// Debug message severity filter.
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT = default_message_severity,
    /// Debug message type filter.
    message_type: vk.DebugUtilsMessageTypeFlagsEXT = default_message_type,
    /// Debug user data pointer.
    user_data: ?*anyopaque = null,
};

const Error = error{
    Overflow,
    CommandLoadFailure,
    UnsupportedInstanceVersion,
    RequiredVersionNotAvailable,
    EnumerateExtensionsFailed,
    RequestedExtensionNotAvailable,
    EnumerateLayersFailed,
    RequestedLayerNotAvailable,
    ValidationLayersNotAvailable,
    DebugMessengerExtensionNotAvailable,
    SurfaceExtensionNotAvailable,
    WindowingExtensionNotAvailable,
};

pub const CreateError = Error ||
    Allocator.Error ||
    vk.BaseWrapper.EnumerateInstanceExtensionPropertiesError ||
    vk.BaseWrapper.EnumerateInstanceLayerPropertiesError ||
    vk.BaseWrapper.CreateInstanceError;

pub fn create(
    allocator: Allocator,
    loader: anytype,
    options: CreateOptions,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
) CreateError!Instance {
    dispatch.base_wrapper = vk.BaseWrapper.load(loader);

    const instance_version_u32 = try dispatch.vkb().enumerateInstanceVersion();
    const instance_version: vk.Version = @bitCast(instance_version_u32);

    if (instance_version_u32 < @as(u32, @bitCast(options.required_api_version)))
        return error.RequiredVersionNotAvailable;
    if (instance_version_u32 < @as(u32, @bitCast(vk.API_VERSION_1_1)))
        return error.UnsupportedInstanceVersion;

    const app_info = vk.ApplicationInfo{
        .p_application_name = options.app_name,
        .application_version = @bitCast(options.app_version),
        .p_engine_name = options.engine_name,
        .engine_version = @bitCast(options.engine_version),
        .api_version = @bitCast(options.required_api_version),
    };

    const available_extensions = try dispatch.vkb().enumerateInstanceExtensionPropertiesAlloc(null, allocator);
    defer allocator.free(available_extensions);

    const available_layers = try dispatch.vkb().enumerateInstanceLayerPropertiesAlloc(allocator);
    defer allocator.free(available_layers);

    const required_extensions = try getRequiredExtensions(allocator, options.required_extensions, available_extensions);
    defer allocator.free(required_extensions);

    const required_layers = try getRequiredLayers(allocator, options.required_layers, available_layers);
    defer allocator.free(required_layers);

    const p_next = if (build_options.enable_validation) &vk.DebugUtilsMessengerCreateInfoEXT{
        .p_next = options.p_next_chain,
        .message_severity = options.debug.message_severity,
        .message_type = options.debug.message_type,
        .pfn_user_callback = options.debug.callback,
        .p_user_data = options.debug.user_data,
    } else options.p_next_chain;

    const portability_enumeration_support = isExtensionAvailable(
        available_extensions,
        vk.extensions.khr_portability_enumeration.name,
    );

    const instance_info = vk.InstanceCreateInfo{
        .flags = if (portability_enumeration_support) .{ .enumerate_portability_bit_khr = true } else .{},
        .p_application_info = &app_info,
        .enabled_extension_count = @as(u32, @intCast(required_extensions.len)),
        .pp_enabled_extension_names = required_extensions.ptr,
        .enabled_layer_count = @as(u32, @intCast(required_layers.len)),
        .pp_enabled_layer_names = required_layers.ptr,
        .p_next = p_next,
    };

    const vki = try allocator.create(vk.InstanceWrapper);
    errdefer allocator.destroy(vki);

    const handle = try dispatch.vkb().createInstance(&instance_info, allocation_callbacks);
    vki.* = vk.InstanceWrapper.load(handle, dispatch.vkb().dispatch.vkGetInstanceProcAddr.?);
    errdefer vki.destroyInstance(handle, options.allocation_callbacks);

    const instance = Instance.init(handle, vki);

    if (build_options.verbose) {
        log.debug("----- instance creation -----", .{});

        log.debug("instance version: {}.{}.{}", .{ instance_version.major, instance_version.minor, instance_version.patch });

        log.debug("validation layers: {s}", .{if (build_options.enable_validation) "enabled" else "disabled"});

        log.debug("available extensions:", .{});
        for (available_extensions) |ext| {
            const ext_name: [*:0]const u8 = @ptrCast(&ext.extension_name);
            log.debug("- {s}", .{ext_name});
        }

        log.debug("available layers:", .{});
        for (available_layers) |layer| {
            const layer_name: [*:0]const u8 = @ptrCast(&layer.layer_name);
            log.debug("- {s}", .{layer_name});
        }

        log.debug("enabled extensions:", .{});
        for (required_extensions) |ext| {
            log.debug("- {s}", .{ext});
        }

        log.debug("enabled layers:", .{});
        for (required_layers) |layer| {
            log.debug("- {s}", .{layer});
        }
    }

    return instance;
}

pub fn createDebugMessenger(
    instance: Instance,
    options: DebugMessengerOptions,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
) !?vk.DebugUtilsMessengerEXT {
    if (!build_options.enable_validation) return null;

    std.debug.assert(instance.handle != .null_handle);

    const debug_info = vk.DebugUtilsMessengerCreateInfoEXT{
        .message_severity = options.message_severity,
        .message_type = options.message_type,
        .pfn_user_callback = options.callback,
        .p_user_data = options.user_data,
    };

    return try instance.createDebugUtilsMessengerEXT(&debug_info, allocation_callbacks);
}

pub fn destroyDebugMessenger(
    instance: Instance,
    debug_messenger: ?vk.DebugUtilsMessengerEXT,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
) void {
    if (!build_options.enable_validation) return;

    std.debug.assert(instance.handle != .null_handle);
    std.debug.assert(debug_messenger != null);

    instance.destroyDebugUtilsMessengerEXT(debug_messenger.?, allocation_callbacks);
}

fn defaultDebugMessageCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    if (p_callback_data) |data| {
        const format = "{?s}";

        if (severity.error_bit_ext) {
            vk_log.err(format, .{data.p_message});
        } else if (severity.warning_bit_ext) {
            vk_log.warn(format, .{data.p_message});
        } else if (severity.info_bit_ext) {
            vk_log.info(format, .{data.p_message});
        } else {
            vk_log.debug(format, .{data.p_message});
        }
    }
    return .false;
}

fn isExtensionAvailable(
    available_extensions: []const vk.ExtensionProperties,
    extension: [*:0]const u8,
) bool {
    for (available_extensions) |ext| {
        const name: [*:0]const u8 = @ptrCast(&ext.extension_name);
        if (std.mem.orderZ(u8, name, extension) == .eq) {
            return true;
        }
    }
    return false;
}

fn addExtension(
    allocator: Allocator,
    available_extensions: []const vk.ExtensionProperties,
    new_extension: [*:0]const u8,
    buffer: *std.ArrayList([*:0]const u8),
) !bool {
    if (isExtensionAvailable(available_extensions, new_extension)) {
        try buffer.append(allocator, new_extension);
        return true;
    }
    return false;
}

fn getRequiredExtensions(
    allocator: Allocator,
    config_extensions: []const [*:0]const u8,
    available_extensions: []const vk.ExtensionProperties,
) ![][*:0]const u8 {
    var required_extensions: std.ArrayList([*:0]const u8) = .empty;

    for (config_extensions) |ext| {
        if (!try addExtension(allocator, available_extensions, ext, &required_extensions)) {
            return error.RequestedExtensionNotAvailable;
        }
    }

    if (!try addExtension(allocator, available_extensions, vk.extensions.khr_surface.name, &required_extensions)) {
        return error.SurfaceExtensionNotAvailable;
    }

    const windowing_extensions: []const [*:0]const u8 = switch (builtin.os.tag) {
        .windows => &.{vk.extensions.khr_win_32_surface.name},
        .macos => &.{vk.extensions.ext_metal_surface.name},
        .linux => &.{
            vk.extensions.khr_xlib_surface.name,
            vk.extensions.khr_xcb_surface.name,
            vk.extensions.khr_wayland_surface.name,
        },
        else => @compileError("unsupported platform"),
    };

    var added_one = false;
    for (windowing_extensions) |ext| {
        added_one = try addExtension(allocator, available_extensions, ext, &required_extensions) or added_one;
    }

    if (!added_one) return error.WindowingExtensionNotAvailable;

    if (build_options.enable_validation) {
        if (!try addExtension(allocator, available_extensions, vk.extensions.ext_debug_utils.name, &required_extensions)) {
            return error.DebugMessengerExtensionNotAvailable;
        }
    }

    _ = addExtension(allocator, available_extensions, vk.extensions.khr_portability_enumeration.name, &required_extensions) catch {};

    return required_extensions.toOwnedSlice(allocator);
}

fn isLayerAvailable(
    available_layers: []const vk.LayerProperties,
    layer: [*:0]const u8,
) bool {
    for (available_layers) |l| {
        const name: [*:0]const u8 = @ptrCast(&l.layer_name);
        if (std.mem.orderZ(u8, name, layer) == .eq) {
            return true;
        }
    }
    return false;
}

fn addLayer(
    allocator: Allocator,
    available_layers: []const vk.LayerProperties,
    new_layer: [*:0]const u8,
    buffer: *std.ArrayList([*:0]const u8),
) !bool {
    if (isLayerAvailable(available_layers, new_layer)) {
        try buffer.append(allocator, new_layer);
        return true;
    }
    return false;
}

fn getRequiredLayers(
    allocator: Allocator,
    config_layers: []const [*:0]const u8,
    available_layers: []const vk.LayerProperties,
) ![][*:0]const u8 {
    var required_layers: std.ArrayList([*:0]const u8) = .empty;

    for (config_layers) |layer| {
        if (!try addLayer(allocator, available_layers, layer, &required_layers)) {
            return error.RequestedLayerNotAvailable;
        }
    }

    if (build_options.enable_validation) {
        for (validation_layers) |layer| {
            if (!try addLayer(allocator, available_layers, layer, &required_layers)) {
                return error.ValidationLayersNotAvailable;
            }
        }
    }

    return required_layers.toOwnedSlice(allocator);
}
