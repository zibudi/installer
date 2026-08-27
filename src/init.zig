const std = @import("std");
const linux = std.os.linux;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var stdout = std.Io.File.stdout().writer(io, &.{});
    const w = &stdout.interface;

    try w.print("\nhello from zibudi\n\n", .{});

    load(io, "/modules/virtio_blk.ko") catch |e|
        try w.print("cannot load virtio_blk: {t}\n", .{e});

    std.Io.Dir.cwd().createDirPath(io, "/sys") catch {};
    if (linux.mount("sysfs", "/sys", "sysfs", 0, 0) != 0)
        try w.print("cannot mount sysfs\n", .{});

    try disks(io, arena, w);
    try std.posix.reboot(.POWER_OFF);
}

fn load(io: std.Io, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const rc = linux.syscall3(.finit_module, @intCast(file.handle), @intFromPtr(""), 0);
    if (rc != 0) return error.FinitModule;
}

fn disks(io: std.Io, arena: std.mem.Allocator, w: *std.Io.Writer) !void {
    try w.print("disks:\n", .{});
    var dir = try std.Io.Dir.cwd().openDir(io, "/sys/block", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const path = try std.fmt.allocPrint(arena, "/sys/block/{s}/size", .{entry.name});
        const size = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64));
        try w.print("  /dev/{s}  {s} sectors\n", .{ entry.name, std.mem.trim(u8, size, "\n") });
    }
}
