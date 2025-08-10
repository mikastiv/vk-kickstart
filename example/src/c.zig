pub usingnamespace @cImport({
    @cInclude("GLFW/glfw3.h");
});
const vk = @import("vulkan");

pub extern fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;
pub extern fn glfwCreateWindowSurface(instance: vk.Instance, window: *@This().GLFWwindow, allocation_callbacks: ?*const vk.AllocationCallbacks, surface: *vk.SurfaceKHR) vk.Result;
