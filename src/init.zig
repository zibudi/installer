//! PID 1.
//!
//! Every kernel built with CONFIG_BLK_DEV_INITRD carries its own three-entry
//! initramfs -- /dev, /dev/console, /root -- which is unpacked before ours and
//! merged under it. The kernel opens that console as fds 0, 1 and 2 before
//! handing over control, so this process can speak the moment it starts.

const std = @import("std");
const linux = std.os.linux;

pub fn main() void {
    _ = linux.write(1, greeting, greeting.len);

    // Returning from PID 1 is a kernel panic. Powering off is how this
    // process is allowed to end, and it makes `zig build qemu` terminate.
    _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
    unreachable;
}

const greeting = "\nhello from zibudi\n\n";
