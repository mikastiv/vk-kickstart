const vk = @import("vulkan");

pub var base_wrapper: ?vk.BaseWrapper = null;

pub fn vkb() *const vk.BaseWrapper {
    return &base_wrapper.?;
}
