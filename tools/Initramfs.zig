//! A build step that writes an initramfs by calling the cpio writer directly.

const std = @import("std");
const cpio = @import("cpio.zig");
const Step = std.Build.Step;
const Initramfs = @This();

step: Step,
entries: []const Entry,
output: std.Build.GeneratedFile,

pub const Entry = union(enum) {
    dir: struct { path: []const u8, mode: u32 },
    node: struct { path: []const u8, mode: u32, kind: cpio.Kind, major: u32, minor: u32 },
    symlink: struct { path: []const u8, target: []const u8 },
    file: struct { path: []const u8, mode: u32, source: std.Build.LazyPath },
};

pub fn create(b: *std.Build, entries: []const Entry) *Initramfs {
    const i = b.allocator.create(Initramfs) catch @panic("OOM");
    i.* = .{
        .step = Step.init(.{ .id = .custom, .name = "initramfs", .owner = b, .makeFn = make }),
        // build() returns long before make() runs; the caller's slice will not survive it.
        .entries = b.allocator.dupe(Entry, entries) catch @panic("OOM"),
        .output = .{ .step = &i.step },
    };
    for (entries) |e| switch (e) {
        .file => |f| f.source.addStepDependencies(&i.step),
        else => {},
    };
    return i;
}

pub fn getOutput(i: *Initramfs) std.Build.LazyPath {
    return .{ .generated = .{ .file = &i.output } };
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const io = b.graph.io;
    const i: *Initramfs = @fieldParentPtr("step", step);

    // No cache manifest. Writing this archive costs about a quarter of a
    // millisecond against a 111ms no-op build, and the bookkeeping to skip it
    // ran longer than the writer. One archive per build, so a fixed path does.
    try b.cache_root.handle.createDirPath(io, "initramfs");
    const path = try b.cache_root.join(b.allocator, &.{ "initramfs", "initramfs.cpio" });

    const out = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer out.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = out.writer(io, &buf);
    var ar: cpio.Archive = .{ .w = &fw.interface };

    for (i.entries) |e| switch (e) {
        .dir => |d| try ar.dir(d.path, d.mode),
        .node => |n| try ar.node(n.path, n.mode, n.kind, n.major, n.minor),
        .symlink => |sl| try ar.symlink(sl.path, sl.target),
        .file => |f| try ar.file(f.path, f.mode, try std.Io.Dir.cwd().readFileAlloc(io, f.source.getPath2(b, step), b.allocator, .unlimited)),
    };
    try ar.finish();

    i.output.path = path;
}
