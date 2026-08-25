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

    // The cache key has to be built by hand: HashHelper.add only knows
    // bool, int, enum and array, so every field is listed explicitly.
    var man = b.graph.cache.obtain();
    defer man.deinit();
    man.hash.addBytes("zibudi-initramfs-v1");
    for (i.entries) |e| {
        man.hash.add(std.meta.activeTag(e));
        switch (e) {
            // A LazyPath is a handle, not a value: what matters is the bytes
            // it resolves to, so the file goes into the manifest instead.
            .file => |f| {
                std.hash.autoHashStrat(&man.hash.hasher, .{ f.path, f.mode }, .DeepRecursive);
                _ = try man.addFile(f.source.getPath2(b, step), null);
            },
            inline else => |v| std.hash.autoHashStrat(&man.hash.hasher, v, .DeepRecursive),
        }
    }

    if (try step.cacheHit(&man)) {
        i.output.path = try b.cache_root.join(b.allocator, &.{ "o", &man.final(), "initramfs.cpio" });
        return;
    }

    const dir = "o" ++ std.fs.path.sep_str ++ man.final();
    try b.cache_root.handle.createDirPath(io, dir);
    const path = try b.cache_root.join(b.allocator, &.{ dir, "initramfs.cpio" });

    const out = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer out.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = out.writer(io, &buf);
    var ar: cpio.Archive = .{ .w = &fw.interface };

    for (i.entries) |e| switch (e) {
        .dir => |d| try ar.dir(d.path, d.mode),
        .node => |n| try ar.node(n.path, n.mode, n.kind, n.major, n.minor),
        .symlink => |s| try ar.symlink(s.path, s.target),
        .file => |f| try ar.file(f.path, f.mode, try std.Io.Dir.cwd().readFileAlloc(io, f.source.getPath2(b, step), b.allocator, .unlimited)),
    };
    try ar.finish();

    i.output.path = path;
    try step.writeManifest(&man);
}
