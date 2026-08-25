//! PID 1.
//!
//! The kernel execs this with no environment, no mounts, and no stdio: it
//! tries to open /dev/console for us, but the initramfs has no device nodes
//! yet, so that fails silently and we start out unable to say anything. The
//! first job is therefore to get a console, and only then to speak.

const std = @import("std");
const linux = std.os.linux;

pub fn main() void {
    // devtmpfs is populated by the kernel, so mounting it is the whole of
    // device setup -- /dev/console exists the instant this returns.
    _ = linux.mount("devtmpfs", "/dev", "devtmpfs", 0, 0);

    const fd = linux.open("/dev/console", .{ .ACCMODE = .WRONLY }, 0);
    _ = linux.write(@intCast(fd), greeting, greeting.len);

    // Returning from PID 1 is a kernel panic. Powering off is how this
    // process is allowed to end, and it makes `zig build qemu` terminate.
    _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
    unreachable;
}

const greeting = "\nhello from zibudi\n\n";
