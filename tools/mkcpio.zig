//! cpio <out> [ dir  <path> <mode>
//!            | nod  <path> <mode> c|b <major> <minor>
//!            | file <path> <mode> <source>
//!            | link <path> <target> ]...

const std = @import("std");
const cpio = @import("cpio.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 2) return error.MissingOutputPath;

    const cwd = std.Io.Dir.cwd();
    const out = try cwd.createFile(io, argv[1], .{});
    defer out.close(io);

    var buf: [64 * 1024]u8 = undefined;
    var fw = out.writer(io, &buf);
    var ar: cpio.Archive = .{ .w = &fw.interface };

    var i: usize = 2;
    while (i < argv.len) {
        const verb = argv[i];
        if (std.mem.eql(u8, verb, "dir")) {
            try ar.dir(argv[i + 1], try mode(argv[i + 2]));
            i += 3;
        } else if (std.mem.eql(u8, verb, "nod")) {
            const kind: cpio.Kind = if (argv[i + 3][0] == 'b') .block else .char;
            try ar.node(argv[i + 1], try mode(argv[i + 2]), kind, try num(argv[i + 4]), try num(argv[i + 5]));
            i += 6;
        } else if (std.mem.eql(u8, verb, "file")) {
            const bytes = try cwd.readFileAlloc(io, argv[i + 3], arena, .unlimited);
            try ar.file(argv[i + 1], try mode(argv[i + 2]), bytes);
            i += 4;
        } else if (std.mem.eql(u8, verb, "link")) {
            try ar.symlink(argv[i + 1], argv[i + 2]);
            i += 3;
        } else return error.UnknownVerb;
    }
    try ar.finish();
}

fn mode(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, s, 8);
}

fn num(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, s, 10);
}
