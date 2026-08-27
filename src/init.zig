const std = @import("std");
const linux = std.os.linux;

pub fn main() void {
    say("\nhello from zibudi\n\n", .{});

    load("/modules/virtio_blk.ko");

    _ = linux.mkdir("/sys", 0o755);
    _ = linux.mount("sysfs", "/sys", "sysfs", 0, 0);
    disks();

    _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
    unreachable;
}

fn load(path: [*:0]const u8) void {
    const fd: isize = @bitCast(linux.open(path, .{ .ACCMODE = .RDONLY }, 0));
    if (fd < 0) return say("cannot open {s}: {d}\n", .{ path, fd });
    defer _ = linux.close(@intCast(fd));
    const rc: isize = @bitCast(linux.syscall3(.finit_module, @intCast(fd), @intFromPtr(""), 0));
    if (rc != 0) say("cannot load {s}: {d}\n", .{ path, rc });
}

fn disks() void {
    say("disks:\n", .{});
    const fd: isize = @bitCast(linux.open("/sys/block", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0));
    if (fd < 0) return say("  cannot read /sys/block: {d}\n", .{fd});
    defer _ = linux.close(@intCast(fd));

    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n: isize = @bitCast(linux.getdents64(@intCast(fd), &buf, buf.len));
        if (n <= 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(n))) {
            const d: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&d.name)), 0);
            off += d.reclen;
            if (name[0] == '.') continue;
            say("  /dev/{s}  {s} sectors\n", .{ name, sectors(name) });
        }
    }
}

fn sectors(name: []const u8) []const u8 {
    var path: [256]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path, "/sys/block/{s}/size", .{name}) catch return "?";
    const fd: isize = @bitCast(linux.open(p.ptr, .{ .ACCMODE = .RDONLY }, 0));
    if (fd < 0) return "?";
    defer _ = linux.close(@intCast(fd));
    const n: isize = @bitCast(linux.read(@intCast(fd), &size_buf, size_buf.len));
    if (n <= 0) return "?";
    return std.mem.trim(u8, size_buf[0..@intCast(n)], "\n");
}

var size_buf: [64]u8 = undefined;
var out_buf: [4096]u8 = undefined;

fn say(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&out_buf, fmt, args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}
