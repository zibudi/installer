const std = @import("std");
const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

const AE = struct {
    const REG: c_uint = 0o100000;
    const DIR: c_uint = 0o040000;
};

fn contents(w: *Writer) !void {
    try w.file("/init", 0o755, w.arg_init);
    try w.tree("/modules", w.arg_modules);
}

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 4) return error.Usage;

    var w: Writer = .{
        .io = init.io,
        .arena = init.arena.allocator(),
        .a = c.archive_write_new() orelse return error.ArchiveInit,
        .arg_init = argv[2],
        .arg_modules = argv[3],
    };
    defer _ = c.archive_write_free(w.a);

    if (c.archive_write_set_format_cpio_newc(w.a) != c.ARCHIVE_OK) return w.fail();
    if (c.archive_write_open_filename(w.a, argv[1].ptr) != c.ARCHIVE_OK) return w.fail();
    try contents(&w);
    if (c.archive_write_close(w.a) != c.ARCHIVE_OK) return w.fail();
}

const Writer = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    a: *c.archive,
    arg_init: []const u8,
    arg_modules: []const u8,
    ino: i64 = 1,

    fn in(w: *Writer, dir_path: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(w.arena, "{s}/{s}", .{ dir_path, name });
    }

    fn tree(w: *Writer, at: []const u8, from: []const u8) !void {
        try w.dir(at, 0o755);
        var root = try std.Io.Dir.cwd().openDir(w.io, from, .{ .iterate = true });
        defer root.close(w.io);
        var walker = try root.walk(w.arena);
        while (try walker.next(w.io)) |entry| {
            const path = try w.in(at, entry.path);
            switch (entry.kind) {
                .directory => try w.dir(path, 0o755),
                .file => try w.file(path, 0o644, try w.in(from, entry.path)),
                else => {},
            }
        }
    }

    fn file(w: *Writer, path: []const u8, mode: u32, source: []const u8) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(w.io, source, w.arena, .unlimited);
        try w.emit(path, AE.REG, mode, 1, bytes);
    }

    fn dir(w: *Writer, path: []const u8, mode: u32) !void {
        try w.emit(path, AE.DIR, mode, 2, "");
    }

    fn emit(w: *Writer, path: []const u8, filetype: c_uint, mode: u32, nlink: c_uint, data: []const u8) !void {
        const e = c.archive_entry_new() orelse return error.EntryInit;
        defer c.archive_entry_free(e);

        var buf: [4096]u8 = undefined;
        const p = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
        c.archive_entry_set_pathname(e, p.ptr);
        c.archive_entry_set_filetype(e, @intCast(filetype));
        c.archive_entry_set_perm(e, @intCast(mode));
        c.archive_entry_set_nlink(e, @intCast(nlink));
        c.archive_entry_set_uid(e, 0);
        c.archive_entry_set_gid(e, 0);
        c.archive_entry_set_mtime(e, 0, 0);
        c.archive_entry_set_ino(e, w.ino);
        c.archive_entry_set_size(e, @intCast(data.len));
        w.ino += 1;

        if (c.archive_write_header(w.a, e) != c.ARCHIVE_OK) return w.fail();
        if (data.len > 0 and c.archive_write_data(w.a, data.ptr, data.len) < 0) return w.fail();
    }

    fn fail(w: *Writer) anyerror {
        if (c.archive_error_string(w.a)) |msg| {
            std.debug.print("mkcpio: {s}\n", .{std.mem.span(msg)});
        } else {
            std.debug.print("mkcpio: unknown libarchive error\n", .{});
        }
        return error.ArchiveFailed;
    }
};
