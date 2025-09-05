const vk = @import("vulkan");
const vkk = @import("vk-kickstart");
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const GraphicsContext = @This();

pub const Instance = vk.InstanceProxy;
pub const Device = vk.DeviceProxy;
pub const Queue = vk.QueueProxy;
pub const CommandBuffer = vk.CommandBufferProxy;

allocator: std.mem.Allocator,
instance: Instance,
debug_messenger: ?vk.DebugUtilsMessengerEXT,
device: Device,
physical_device: vkk.PhysicalDevice,
surface: vk.SurfaceKHR,
graphics_queue_index: u32,
present_queue_index: u32,
graphics_queue: Queue,
present_queue: Queue,

pub fn init(allocator: std.mem.Allocator, window: *c.GLFWwindow) !GraphicsContext {
    const is_debug = builtin.mode == .Debug;

    const instance = try vkk.instance.create(
        allocator,
        c.glfwGetInstanceProcAddress,
        .{
            .required_api_version = vk.API_VERSION_1_3,
            .enable_validation = true,
            .debug_messenger = .{ .enable = true },
        },
        null,
    );
    errdefer instance.destroyInstance(null);

    const debug_messenger = switch (is_debug) {
        true => try vkk.instance.createDebugMessenger(instance, .{}, null),
        false => .null_handle,
    };
    errdefer if (is_debug) vkk.instance.destroyDebugMessenger(instance, debug_messenger, null);

    var surface: vk.SurfaceKHR = .null_handle;
    if (c.glfwCreateWindowSurface(instance.handle, window, null, &surface) != .success)
        return error.SurfaceInitFailed;
    errdefer instance.destroySurfaceKHR(surface, null);

    const physical_device = try vkk.PhysicalDevice.select(allocator, instance, .{
        .surface = surface,
        .required_api_version = vk.API_VERSION_1_2,
        .required_extensions = &.{
            vk.extensions.khr_ray_tracing_pipeline.name,
            vk.extensions.khr_acceleration_structure.name,
            vk.extensions.khr_deferred_host_operations.name,
            vk.extensions.khr_buffer_device_address.name,
            vk.extensions.ext_descriptor_indexing.name,
        },
        .required_features = .{
            .sampler_anisotropy = .true,
        },
        .required_features_12 = .{
            .descriptor_indexing = .true,
        },
    });
    errdefer physical_device.deinit();

    std.log.info("selected {s}", .{physical_device.name()});

    var rt_features = vk.PhysicalDeviceRayTracingPipelineFeaturesKHR{
        .ray_tracing_pipeline = .true,
    };

    const device = try vkk.device.create(allocator, instance, &physical_device, @ptrCast(&rt_features), null);
    errdefer device.destroyDevice(null);

    const graphics_queue_index = physical_device.graphics_queue_index;
    const present_queue_index = physical_device.present_queue_index;
    const graphics_queue_handle = device.getDeviceQueue(graphics_queue_index, 0);
    const present_queue_handle = device.getDeviceQueue(present_queue_index, 0);
    const graphics_queue = Queue.init(graphics_queue_handle, device.wrapper);
    const present_queue = Queue.init(present_queue_handle, device.wrapper);

    return .{
        .allocator = allocator,
        .instance = instance,
        .debug_messenger = debug_messenger,
        .device = device,
        .physical_device = physical_device,
        .surface = surface,
        .graphics_queue_index = graphics_queue_index,
        .present_queue_index = present_queue_index,
        .graphics_queue = graphics_queue,
        .present_queue = present_queue,
    };
}

pub fn deinit(self: *GraphicsContext) void {
    self.device.destroyDevice(null);
    self.instance.destroySurfaceKHR(self.surface, null);
    vkk.instance.destroyDebugMessenger(self.instance, self.debug_messenger, null);
    self.instance.destroyInstance(null);
    self.physical_device.deinit();
    self.allocator.destroy(self.instance.wrapper);
    self.allocator.destroy(self.device.wrapper);
}
