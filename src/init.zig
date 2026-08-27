const std = @import("std");
const vaxis = @import("vaxis");
const center = vaxis.widgets.alignment.center;
const linux = std.os.linux;

const wanted = [_][]const u8{ "virtio_blk", "nvme", "ahci", "sd_mod" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    try mountFilesystems(io);
    try claimConsole(io, arena);
    try loadDrivers(io, arena);
    if (try present(io, arena, init.environ_map, try disks(io, arena))) |disk| {
        var out = std.Io.File.stdout().writer(io, &.{});
        try out.interface.print("\ninstalling to /dev/{s}\n\n", .{disk.name});
    }

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

    linux.setsid();
    const tty = try std.Io.Dir.openFileAbsolute(io, try std.fmt.allocPrint(arena, "/dev/{s}", .{last}), .{ .mode = .read_write });
    _ = linux.ioctl(tty.handle, linux.T.IOCSCTTY, 0);

    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    _ = linux.ioctl(tty.handle, linux.T.IOCGWINSZ, @intFromPtr(&size));
    if (size.col == 0) {
        size = measure(tty.handle) orelse .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        _ = linux.ioctl(tty.handle, linux.T.IOCSWINSZ, @intFromPtr(&size));
    }
}

fn measure(handle: std.posix.fd_t) ?std.posix.winsize {
    const saved = std.posix.tcgetattr(handle) catch return null;
    var raw = saved;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 20;
    std.posix.tcsetattr(handle, .FLUSH, raw) catch return null;
    defer std.posix.tcsetattr(handle, .FLUSH, saved) catch {};

    const ask = "\x1b[9999;9999H\x1b[6n";
    _ = linux.write(handle, ask.ptr, ask.len);

    var buf: [32]u8 = undefined;
    const n: isize = @bitCast(linux.read(handle, &buf, buf.len));
    if (n < 6) return null;
    const reply = buf[0..@intCast(n)];
    if (reply[0] != 0x1b or reply[1] != '[') return null;
    const semi = std.mem.indexOfScalar(u8, reply, ';') orelse return null;
    const end = std.mem.indexOfScalar(u8, reply, 'R') orelse return null;
    return .{
        .row = std.fmt.parseInt(u16, reply[2..semi], 10) catch return null,
        .col = std.fmt.parseInt(u16, reply[semi + 1 .. end], 10) catch return null,
        .xpixel = 0,
        .ypixel = 0,
    };
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
        const sectors = attribute(io, arena, entry.name, "size") orelse continue;
        const removable = attribute(io, arena, entry.name, "removable") orelse continue;
        if (sectors == 0 or removable != 0) continue;
        try found.append(arena, .{ .name = try arena.dupe(u8, entry.name), .bytes = sectors * 512 });
    }
    std.mem.sort(Disk, found.items, {}, byName);
    return found.items;
}

fn byName(_: void, a: Disk, b: Disk) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn attribute(io: std.Io, arena: std.mem.Allocator, name: []const u8, of: []const u8) ?u64 {
    const path = std.fmt.allocPrint(arena, "/sys/block/{s}/{s}", .{ name, of }) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64)) catch return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch null;
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const frame: vaxis.Style = .{ .fg = .{ .index = 4 } };
const heading: vaxis.Style = .{ .bold = true };
const chosen_row: vaxis.Style = .{ .fg = .{ .index = 4 }, .reverse = true, .bold = true };
const quiet: vaxis.Style = .{ .dim = true };

fn present(io: std.Io, arena: std.mem.Allocator, environ: *std.process.Environ.Map, found: []const Disk) !?Disk {
    var buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, arena, environ, .{});
    defer vx.deinit(arena, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());

    var cursor: usize = 0;
    while (true) {
        draw(vx.window(), arena, found, cursor);
        try vx.render(tty.writer());

        switch (try loop.nextEvent()) {
            .winsize => |size| try vx.resize(arena, tty.writer(), size),
            .key_press => |key| {
                if (key.matchesAny(&.{ 'q', vaxis.Key.escape }, .{})) return null;
                if (key.matchesAny(&.{ 'k', vaxis.Key.up }, .{})) cursor -|= 1;
                if (key.matchesAny(&.{ 'j', vaxis.Key.down }, .{})) cursor = @min(cursor + 1, found.len -| 1);
                if (key.matches(vaxis.Key.enter, .{}) and found.len > 0) return found[cursor];
            },
        }
    }
}

fn draw(window: vaxis.Window, arena: std.mem.Allocator, found: []const Disk, cursor: usize) void {
    window.clear();
    const listed: u16 = @intCast(@max(found.len, 1));
    const card = center(window, @min(window.width -| 4, 72), @min(window.height -| 2, listed + 7))
        .child(.{ .border = .{ .where = .all, .style = frame } });

    _ = card.printSegment(.{ .text = "zibudi", .style = heading }, .{ .row_offset = 0, .col_offset = 2 });
    _ = card.printSegment(.{ .text = "select a disk to install to", .style = quiet }, .{ .row_offset = 1, .col_offset = 2 });

    for (found, 0..) |disk, index| {
        _ = card.printSegment(.{
            .text = listing(arena, card.width, disk),
            .style = if (index == cursor) chosen_row else .{},
        }, .{ .row_offset = @intCast(index + 3), .col_offset = 0 });
    }
    if (found.len == 0)
        _ = card.printSegment(.{ .text = "  no disks found", .style = quiet }, .{ .row_offset = 3, .col_offset = 0 });

    _ = card.printSegment(
        .{ .text = "\u{2191}\u{2193} move    \u{23ce} install    q quit", .style = quiet },
        .{ .row_offset = card.height -| 1, .col_offset = 2 },
    );
}

fn listing(arena: std.mem.Allocator, width: u16, disk: Disk) []const u8 {
    const size = capacity(arena, disk.bytes);
    const line = arena.alloc(u8, width) catch return disk.name;
    @memset(line, ' ');
    _ = std.fmt.bufPrint(line, "  /dev/{s}", .{disk.name}) catch {};
    if (size.len + 2 <= width) @memcpy(line[width -| size.len -| 2..][0..size.len], size);
    return line;
}

fn capacity(arena: std.mem.Allocator, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1000 and unit + 1 < units.len) : (unit += 1) value /= 1000;
    return std.fmt.allocPrint(arena, "{d:.0} {s}", .{ value, units[unit] }) catch "?";
}
