//! mkcpio <out> [ dir  <path> <mode>
//!              | nod  <path> <mode> c|b <major> <minor>
//!              | file <path> <mode> <source>
//!              | link <path> <target> ]...
//!
//! Drives libarchive's newc encoder rather than emitting the format here.
//! Every field is stated instead of read off the build machine, so the same
//! arguments produce the same bytes on any host.

const std = @import("std");
const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

// archive_entry.h spells these as casts -- ((__LA_MODE_T)0040000) -- which
// translate-c will not follow. They are the standard S_IF* values.
const AE = struct {
    const IFREG: c_uint = 0o100000;
    const IFLNK: c_uint = 0o120000;
    const IFCHR: c_uint = 0o020000;
    const IFBLK: c_uint = 0o060000;
    const IFDIR: c_uint = 0o040000;
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 2) return error.MissingOutputPath;

    const a = c.archive_write_new() orelse return error.ArchiveInit;
    defer _ = c.archive_write_free(a);
    if (c.archive_write_set_format_cpio_newc(a) != c.ARCHIVE_OK) return fail(a);
    if (c.archive_write_open_filename(a, argv[1].ptr) != c.ARCHIVE_OK) return fail(a);

    var ino: i64 = 1;
    var i: usize = 2;
    while (i < argv.len) {
        const verb = argv[i];
        if (std.mem.eql(u8, verb, "dir")) {
            // Two links: the entry in its parent, and its own ".".
            try emit(a, argv[i + 1], AE.IFDIR, try mode(argv[i + 2]), &ino, 2, 0, 0, "");
            i += 3;
        } else if (std.mem.eql(u8, verb, "nod")) {
            const kind: c_uint = if (argv[i + 3][0] == 'b') AE.IFBLK else AE.IFCHR;
            try emit(a, argv[i + 1], kind, try mode(argv[i + 2]), &ino, 1, try num(argv[i + 4]), try num(argv[i + 5]), "");
            i += 6;
        } else if (std.mem.eql(u8, verb, "file")) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, argv[i + 3], arena, .unlimited);
            try emit(a, argv[i + 1], AE.IFREG, try mode(argv[i + 2]), &ino, 1, 0, 0, bytes);
            i += 4;
        } else if (std.mem.eql(u8, verb, "link")) {
            try emit(a, argv[i + 1], AE.IFLNK, 0o777, &ino, 1, 0, 0, argv[i + 2]);
            i += 3;
        } else return error.UnknownVerb;
    }
    if (c.archive_write_close(a) != c.ARCHIVE_OK) return fail(a);
}

fn emit(
    a: *c.archive,
    path: []const u8,
    filetype: c_uint,
    perm: u32,
    ino: *i64,
    nlink: c_uint,
    major: u32,
    minor: u32,
    data: []const u8,
) !void {
    const e = c.archive_entry_new() orelse return error.EntryInit;
    defer c.archive_entry_free(e);

    var buf: [4096]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    c.archive_entry_set_pathname(e, z.ptr);
    c.archive_entry_set_filetype(e, @intCast(filetype));
    c.archive_entry_set_perm(e, @intCast(perm));
    c.archive_entry_set_nlink(e, @intCast(nlink));

    // Stated, never read: an archive that carries the build machine's clock
    // and inode numbers is a different archive every time.
    c.archive_entry_set_uid(e, 0);
    c.archive_entry_set_gid(e, 0);
    c.archive_entry_set_mtime(e, 0, 0);
    c.archive_entry_set_ino(e, ino.*);
    ino.* += 1;

    if (filetype == AE.IFCHR or filetype == AE.IFBLK) {
        c.archive_entry_set_rdevmajor(e, @intCast(major));
        c.archive_entry_set_rdevminor(e, @intCast(minor));
    }
    if (filetype == AE.IFLNK) {
        const t = try std.fmt.bufPrintZ(buf[z.len + 1 ..], "{s}", .{data});
        c.archive_entry_set_symlink(e, t.ptr);
        // The newc writer stores the target where a file's body goes, and
        // wants the length up front like any other entry.
        c.archive_entry_set_size(e, @intCast(data.len));
    } else {
        c.archive_entry_set_size(e, @intCast(data.len));
    }

    if (c.archive_write_header(a, e) != c.ARCHIVE_OK) return fail(a);
    if (filetype == AE.IFREG and data.len > 0) {
        if (c.archive_write_data(a, data.ptr, data.len) < 0) return fail(a);
    }
}

fn fail(a: *c.archive) anyerror {
    if (c.archive_error_string(a)) |msg| {
        std.debug.print("mkcpio: {s}\n", .{std.mem.span(msg)});
    } else {
        std.debug.print("mkcpio: unknown libarchive error\n", .{});
    }
    return error.ArchiveFailed;
}

fn mode(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, s, 8);
}
fn num(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, s, 10);
}
