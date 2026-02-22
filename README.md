# `vk-kickstart`

A Zig library to help with Vulkan initialization inspired by [vk-bootstrap](https://github.com/charles-lunarg/vk-bootstrap)

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

