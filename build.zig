const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux });
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = .ReleaseSmall });
    const init = b.addExecutable(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/init.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "vaxis", .module = vaxis.module("vaxis") }},
        }),
    });

    const host = b.graph.host;
    const libarchive = b.dependency("libarchive", .{ .target = host, .optimize = .ReleaseSafe });
    const mkcpio_mod = b.createModule(.{
        .root_source_file = b.path("tools/mkcpio.zig"),
        .target = host,
        .optimize = .ReleaseSafe,
    });
    mkcpio_mod.linkLibrary(libarchive.artifact("archive"));
    const mkcpio = b.addExecutable(.{ .name = "mkcpio", .root_module = mkcpio_mod });

    const linux = b.dependency("linux", .{});
    const kernel = linux.namedLazyPath("vmlinuz");
    const initramfs = buildInitramfs(b, mkcpio, init, linux.namedLazyPath("modules"));

    b.getInstallStep().dependOn(&b.addInstallFile(initramfs, "initramfs.cpio").step);
    b.getInstallStep().dependOn(&b.addInstallFile(kernel, "vmlinuz").step);

    const qemu = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M",
        "q35",
        "-m",
        "512",
        "-display",
        "none",
        "-serial",
        "stdio",
        "-monitor",
        "none",
        "-no-reboot",
        "-append",
        "console=ttyS0",
    });
    qemu.addArg("-kernel");
    qemu.addFileArg(kernel);
    qemu.addArg("-initrd");
    qemu.addFileArg(initramfs);
    for ([_][]const u8{ "256M", "3G" }) |size| {
        qemu.addArg("-drive");
        qemu.addPrefixedFileArg("if=virtio,format=raw,file=", scratchDisk(b, size));
    }
    qemu.has_side_effects = true;

    b.step("qemu", "boot the initramfs and print what init says")
        .dependOn(&qemu.step);
}

fn scratchDisk(b: *std.Build, size: []const u8) std.Build.LazyPath {
    const create = b.addSystemCommand(&.{ "qemu-img", "create", "-f", "raw" });
    const img = create.addOutputFileArg("disk.img");
    create.addArg(size);
    return img;
}

fn buildInitramfs(
    b: *std.Build,
    mkcpio: *std.Build.Step.Compile,
    init: *std.Build.Step.Compile,
    modules: std.Build.LazyPath,
) std.Build.LazyPath {
    const run = b.addRunArtifact(mkcpio);
    const initramfs = run.addOutputFileArg("initramfs.cpio");
    run.addArtifactArg(init);
    run.addDirectoryArg(modules);
    return initramfs;
}
