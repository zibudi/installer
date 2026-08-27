const std = @import("std");
const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

const AE = struct {
    const REG: c_uint = 0o100000;
    const LNK: c_uint = 0o120000;
    const CHR: c_uint = 0o020000;
    const DIR: c_uint = 0o040000;
};

fn contents(w: *Writer) !void {
    try w.file("/init", 0o755, w.arg_init);
    try w.dir("/modules", 0o755);
    try w.file("/modules/virtio_blk.ko", 0o644, try w.in(w.arg_modules, "virtio_blk.ko"));
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

    fn file(w: *Writer, path: []const u8, mode: u32, source: []const u8) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(w.io, source, w.arena, .unlimited);
        try w.emit(path, AE.REG, mode, 1, 0, 0, bytes);
    }

    fn dir(w: *Writer, path: []const u8, mode: u32) !void {
        try w.emit(path, AE.DIR, mode, 2, 0, 0, "");
    }

    fn node(w: *Writer, path: []const u8, mode: u32, major: u32, minor: u32) !void {
        try w.emit(path, AE.CHR, mode, 1, major, minor, "");
    }

    fn symlink(w: *Writer, path: []const u8, target: []const u8) !void {
        try w.emit(path, AE.LNK, 0o777, 1, 0, 0, target);
    }

    fn emit(
        w: *Writer,
        path: []const u8,
        filetype: c_uint,
        mode: u32,
        nlink: c_uint,
        major: u32,
        minor: u32,
        data: []const u8,
    ) !void {
        const e = c.archive_entry_new() orelse return error.EntryInit;
        defer c.archive_entry_free(e);

        var buf: [4096]u8 = undefined;
        const p = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
        c.archive_entry_set_pathname(e, p.ptr);
        c.archive_entry_set_filetype(e, @intCast(filetype));
        c.archive_entry_set_perm(e, @intCast(mode));
        c.archive_entry_set_nlink(e, @intCast(nlink));
        c.archive_entry_set_rdevmajor(e, @intCast(major));
        c.archive_entry_set_rdevminor(e, @intCast(minor));

        c.archive_entry_set_uid(e, 0);
        c.archive_entry_set_gid(e, 0);
        c.archive_entry_set_mtime(e, 0, 0);
        c.archive_entry_set_ino(e, w.ino);
        w.ino += 1;

        if (filetype == AE.LNK) {
            const t = try std.fmt.bufPrintZ(buf[p.len + 1 ..], "{s}", .{data});
            c.archive_entry_set_symlink(e, t.ptr);
        }
        c.archive_entry_set_size(e, @intCast(data.len));

        if (c.archive_write_header(w.a, e) != c.ARCHIVE_OK) return w.fail();
        if (filetype == AE.REG and data.len > 0) {
            if (c.archive_write_data(w.a, data.ptr, data.len) < 0) return w.fail();
        }
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
