//! Writes the newc cpio format, which is the only thing Linux will unpack as
//! an initramfs. Nothing here reads metadata off the build machine: every
//! field is stated, so the same inputs give the same bytes everywhere.

const std = @import("std");

pub const Kind = enum(u32) {
    file = 0o100000,
    dir = 0o040000,
    char = 0o020000,
    block = 0o060000,
    symlink = 0o120000,
};

pub const Archive = struct {
    w: *std.Io.Writer,
    /// Inodes only have to be distinct, never meaningful.
    ino: u32 = 1,
    written: usize = 0,

    pub fn dir(a: *Archive, path: []const u8, mode: u32) !void {
        // Two links: the entry in its parent, and its own ".".
        try a.entry(path, @intFromEnum(Kind.dir) | mode, 2, 0, 0, "");
    }

    pub fn node(a: *Archive, path: []const u8, mode: u32, kind: Kind, major: u32, minor: u32) !void {
        try a.entry(path, @intFromEnum(kind) | mode, 1, major, minor, "");
    }

    pub fn symlink(a: *Archive, path: []const u8, target: []const u8) !void {
        // A symlink's target is stored where a file's contents would go.
        try a.entry(path, @intFromEnum(Kind.symlink) | 0o777, 1, 0, 0, target);
    }

    pub fn file(a: *Archive, path: []const u8, mode: u32, bytes: []const u8) !void {
        try a.entry(path, @intFromEnum(Kind.file) | mode, 1, 0, 0, bytes);
    }

    pub fn finish(a: *Archive) !void {
        a.ino = 0;
        try a.entry("TRAILER!!!", 0, 1, 0, 0, "");
        // Tail padding to a 512-byte block is convention, not format.
        try a.w.splatByteAll(0, (512 - (a.written % 512)) % 512);
        try a.w.flush();
    }

    fn entry(
        a: *Archive,
        path: []const u8,
        mode: u32,
        nlink: u32,
        major: u32,
        minor: u32,
        data: []const u8,
    ) !void {
        // Archive members are relative; the kernel unpacks them into rootfs.
        const name = std.mem.trimStart(u8, path, "/");
        const w = a.w;

        try w.writeAll("070701");
        for ([_]u32{
            a.ino,
            mode,
            0, // uid: root, always
            0, // gid: root, always
            nlink,
            0, // mtime: zeroed, or the archive is a clock
            @intCast(data.len),
            0, // devmajor
            0, // devminor
            major,
            minor,
            @intCast(name.len + 1),
            0, // check: unused outside the crc variant
        }) |field| try w.print("{x:0>8}", .{field});

        try w.writeAll(name);
        try w.writeByte(0);
        a.written += 110 + name.len + 1;
        try a.pad();

        try w.writeAll(data);
        a.written += data.len;
        try a.pad();

        a.ino += 1;
    }

    fn pad(a: *Archive) !void {
        const n = (4 - (a.written % 4)) % 4;
        try a.w.splatByteAll(0, n);
        a.written += n;
    }
};
