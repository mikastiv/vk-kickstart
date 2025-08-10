# `vk-kickstart`

A Zig library to help with Vulkan initialization inspired by [vk-bootstrap](https://github.com/charles-lunarg/vk-bootstrap)

The minimum required version is Vulkan 1.1

This library helps with:
- Instance creation
- Setting up debug environment (validation layers and debug messenger)
- Physical device selection based on a set of criteria
- Enabling physical device extensions
- Device creation
- Swapchain creation
- Getting queues

## Setting up

Add vk-kickstart:
```
zig fetch --save https://github.com/Mikastiv/vk-kickstart/archive/<COMMIT_HASH>.tar.gz
```

Then update your build file with the following:
```zig
// Provide the Vulkan registry
const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
const vk_kickstart = b.dependency("vk_kickstart", .{
    .registry = registry,
    // Enable validation layers and debug messenger
    .enable_validation = if (optimize == .Debug) true else false,
    // Verbose output
    .verbose = true,
});

// Import vk-kickstart
exe.root_module.addImport("vk-kickstart", vk_kickstart.module("vk-kickstart"));
exe.root_module.addImport("vulkan", vk_kickstart.module("vulkan"));
 ```

You can then import `vk-kickstart` as a module and vulkan-zig
```zig
const vkk = @import("vk-kickstart");
const vk = @import("vulkan");
```

See [build.zig](example/build.zig) for an example

## How to use

For a code example, see [main.zig](example/src/main.zig)

### Instance creation

Using the `instance.CreateOptions` struct's fields, you can you can choose how you want the instance to be configured like the required api version.

Note: VK_KHR_surface and the platform specific surface extension are automatically enabled. Only works for Windows, MacOS and Linux (xcb, xlib or wayland) for now

```zig
const vk = @import("vulkan-zig");

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
```

Pass these options to `instance.create()` to create an instance

### Physical device selection

You can set criterias to select an appropriate physical device for your application using `PhysicalDevice.SelectOptions`

Note: VK_KHR_subset (if available) and VK_KHR_swapchain are automatically enabled, no need to add them to the list

```zig
const vk = @import("vulkan-zig");

pub const SelectOptions = struct {
    /// Vulkan render surface.
    surface: vk.SurfaceKHR,
    /// Name of the device to select.
    name: ?[*:0]const u8 = null,
    /// Required Vulkan version (minimum 1.1).
    required_api_version: u32 = vk.API_VERSION_1_1,
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
    /// Array of required physical device extensions to enable.
    /// Note: VK_KHR_swapchain and VK_KHR_subset (if available) are automatically enabled.
    required_extensions: []const [*:0]const u8 = &.{},
};
```

Pass these options to `PhysicalDevice.select()` to select a device

### Device creation

For this, you only need to call `device.create()` with the previously selected physical device

### Swapchain creation

Finally to create a swapchain, use `Swapchain.CreateOptions`

```zig
const vk = @import("vulkan-zig");

pub const CreateOptions = struct {
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
    clipped: vk.Bool32 = vk.TRUE,
    /// Existing non-retired swapchain currently associated with surface
    old_swapchain: ?vk.SwapchainKHR = null,
    /// pNext chain
    p_next_chain: ?*anyopaque = null,
};
```

Pass these options and a the logical device to `Swapchain.create()` to create the swapchain

## Todo list
- Headless mode
