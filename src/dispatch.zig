const vk = @import("vulkan");
const build_options = @import("build_options");

pub const BaseWrapper = vk.BaseWrapper;
pub const InstanceWrapper = vk.InstanceWrapper;
pub const DeviceWrapper = vk.DeviceWrapper;

pub var vkb_table: ?BaseWrapper = null;
pub var vki_table: ?InstanceWrapper = null;
pub var vkd_table: ?DeviceWrapper = null;

pub fn vkb() *const BaseWrapper {
    return &vkb_table.?;
}

pub fn vki() *const InstanceWrapper {
    return &vki_table.?;
}

pub fn vkd() *const DeviceWrapper {
    return &vkd_table.?;
}
