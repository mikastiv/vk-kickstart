const vk = @import("vulkan");
const vkk = @import("vk-kickstart");
const std = @import("std");
const Window = @import("Window.zig");
const c = @import("c.zig");
const GraphicsContext = @This();

pub const InstanceDispatch = vk.InstanceWrapper;
pub const DeviceDispatch = vk.DeviceWrapper;
pub const Instance = vk.InstanceProxy;
pub const Device = vk.DeviceProxy;
pub const Queue = vk.QueueProxy;
pub const CommandBuffer = vk.CommandBufferProxy;

vki: *InstanceDispatch,
vkd: *DeviceDispatch,
instance: Instance,
debug_messenger: ?vk.DebugUtilsMessengerEXT,
device: Device,
physical_device: vkk.PhysicalDevice,
surface: vk.SurfaceKHR,
graphics_queue_index: u32,
present_queue_index: u32,
graphics_queue: Queue,
present_queue: Queue,

pub fn init(allocator: std.mem.Allocator, window: *const Window) !GraphicsContext {
    const vki = try allocator.create(InstanceDispatch);
    errdefer allocator.destroy(vki);

    const vkd = try allocator.create(DeviceDispatch);
    errdefer allocator.destroy(vkd);

    const instance_handle = try vkk.instance.create(
        c.glfwGetInstanceProcAddress,
        .{ .required_api_version = vk.API_VERSION_1_3 },
        null,
    );
    vki.* = InstanceDispatch.load(instance_handle, c.glfwGetInstanceProcAddress);
    const instance = Instance.init(instance_handle, vki);
    errdefer instance.destroyInstance(null);

    const debug_messenger = try vkk.instance.createDebugMessenger(instance.handle, .{}, null);
    errdefer vkk.instance.destroyDebugMessenger(instance.handle, debug_messenger, null);

    const surface = try window.createSurface(instance.handle);
    errdefer instance.destroySurfaceKHR(surface, null);

    const physical_device = try vkk.PhysicalDevice.select(instance.handle, .{
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
            .sampler_anisotropy = vk.TRUE,
        },
        .required_features_12 = .{
            .descriptor_indexing = vk.TRUE,
        },
    });

    std.log.info("selected {s}", .{physical_device.name()});

    var rt_features = vk.PhysicalDeviceRayTracingPipelineFeaturesKHR{
        .ray_tracing_pipeline = vk.TRUE,
    };

    const device_handle = try vkk.device.create(&physical_device, @ptrCast(&rt_features), null);
    vkd.* = DeviceDispatch.load(device_handle, vki.dispatch.vkGetDeviceProcAddr.?);
    const device = Device.init(device_handle, vkd);
    errdefer device.destroyDevice(null);

    const graphics_queue_index = physical_device.graphics_queue_index;
    const present_queue_index = physical_device.present_queue_index;
    const graphics_queue_handle = device.getDeviceQueue(graphics_queue_index, 0);
    const present_queue_handle = device.getDeviceQueue(present_queue_index, 0);
    const graphics_queue = Queue.init(graphics_queue_handle, vkd);
    const present_queue = Queue.init(present_queue_handle, vkd);

    return .{
        .vki = vki,
        .vkd = vkd,
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

pub fn deinit(self: *GraphicsContext, allocator: std.mem.Allocator) void {
    self.device.destroyDevice(null);
    self.instance.destroySurfaceKHR(self.surface, null);
    vkk.instance.destroyDebugMessenger(self.instance.handle, self.debug_messenger, null);
    self.instance.destroyInstance(null);
    allocator.destroy(self.vki);
    allocator.destroy(self.vkd);
}
