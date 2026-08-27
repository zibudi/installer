const std = @import("std");
const vaxis = @import("vaxis");
const linux = std.os.linux;

const wanted = [_][]const u8{ "virtio_blk", "nvme", "ahci", "sd_mod" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    try mountFilesystems(io);
    try claimConsole(io, arena);
    try loadDrivers(io, arena);
    try present(io, arena, init.environ_map, try disks(io, arena));

    try std.posix.reboot(.POWER_OFF);
}

fn mountFilesystems(io: std.Io) !void {
    try std.Io.Dir.cwd().createDirPath(io, "/sys");
    _ = linux.mount("sysfs", "/sys", "sysfs", 0, 0);
    _ = linux.mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
}

fn claimConsole(io: std.Io, arena: std.mem.Allocator) !void {
    const active = try std.Io.Dir.cwd().readFileAlloc(io, "/sys/class/tty/console/active", arena, .limited(64));
    var names = std.mem.tokenizeAny(u8, active, " \n");
    var last: []const u8 = "console";
    while (names.next()) |name| last = name;

    _ = linux.setsid();
    const tty = try std.Io.Dir.openFileAbsolute(io, try std.fmt.allocPrint(arena, "/dev/{s}", .{last}), .{ .mode = .read_write });
    _ = linux.ioctl(tty.handle, linux.T.IOCSCTTY, 0);

    var size: std.posix.winsize = undefined;
    _ = linux.ioctl(tty.handle, linux.T.IOCGWINSZ, @intFromPtr(&size));
    if (size.col == 0) {
        size = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        _ = linux.ioctl(tty.handle, linux.T.IOCSWINSZ, @intFromPtr(&size));
    }
}

fn loadDrivers(io: std.Io, arena: std.mem.Allocator) !void {
    const dep = try std.Io.Dir.cwd().readFileAlloc(io, "/modules/modules.dep", arena, .unlimited);
    for (wanted) |name| insert(io, arena, dep, name) catch {};
}

fn insert(io: std.Io, arena: std.mem.Allocator, dep: []const u8, name: []const u8) !void {
    const line = entryFor(arena, dep, name) orelse return error.NoSuchModule;
    const colon = std.mem.indexOfScalar(u8, line, ':').?;

    var deps = std.mem.splitBackwardsScalar(u8, line[colon + 1 ..], ' ');
    while (deps.next()) |dependency| {
        const trimmed = std.mem.trim(u8, dependency, " ");
        if (trimmed.len > 0) try finit(io, arena, trimmed);
    }
    try finit(io, arena, line[0..colon]);
}

fn entryFor(arena: std.mem.Allocator, dep: []const u8, name: []const u8) ?[]const u8 {
    const suffix = std.fmt.allocPrint(arena, "/{s}.ko", .{name}) catch return null;
    var lines = std.mem.splitScalar(u8, dep, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.endsWith(u8, line[0..colon], suffix)) return line;
    }
    return null;
}

fn finit(io: std.Io, arena: std.mem.Allocator, relative: []const u8) !void {
    const file = try std.Io.Dir.openFileAbsolute(io, try std.fmt.allocPrint(arena, "/modules/{s}", .{relative}), .{});
    defer file.close(io);
    const rc = linux.syscall3(.finit_module, @intCast(file.handle), @intFromPtr(""), 0);
    switch (linux.errno(rc)) {
        .SUCCESS, .EXIST => {},
        else => return error.CannotLoadModule,
    }
}

const Disk = struct {
    name: []const u8,
    bytes: u64,
};

fn disks(io: std.Io, arena: std.mem.Allocator) ![]const Disk {
    var found: std.ArrayList(Disk) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, "/sys/block", .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const path = try std.fmt.allocPrint(arena, "/sys/block/{s}/size", .{entry.name});
        const size = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64)) catch continue;
        const sectors = std.fmt.parseInt(u64, std.mem.trim(u8, size, " \n"), 10) catch continue;
        try found.append(arena, .{ .name = try arena.dupe(u8, entry.name), .bytes = sectors * 512 });
    }
    return found.items;
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

fn present(io: std.Io, arena: std.mem.Allocator, environ: *std.process.Environ.Map, found: []const Disk) !void {
    var buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, arena, environ, .{});
    defer vx.deinit(arena, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());

    while (true) {
        const window = vx.window();
        window.clear();
        draw(window, arena, found);
        try vx.render(tty.writer());

        switch (try loop.nextEvent()) {
            .key_press => |key| if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) return,
            .winsize => |size| try vx.resize(arena, tty.writer(), size),
        }
    }
}

fn draw(window: vaxis.Window, arena: std.mem.Allocator, found: []const Disk) void {
    _ = window.printSegment(.{ .text = "zibudi" }, .{ .row_offset = 0, .col_offset = 2 });
    _ = window.printSegment(.{ .text = "select a disk to install to" }, .{ .row_offset = 1, .col_offset = 2 });

    for (found, 0..) |disk, index| {
        const line = std.fmt.allocPrint(arena, "/dev/{s}   {d:.1} GB", .{ disk.name, gigabytes(disk.bytes) }) catch continue;
        _ = window.printSegment(.{ .text = line }, .{ .row_offset = @intCast(3 + index), .col_offset = 4 });
    }
    if (found.len == 0)
        _ = window.printSegment(.{ .text = "no disks found" }, .{ .row_offset = 3, .col_offset = 4 });

    _ = window.printSegment(.{ .text = "q to quit" }, .{ .row_offset = @intCast(4 + found.len), .col_offset = 2 });
}

fn gigabytes(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1000.0 * 1000.0 * 1000.0);
}
