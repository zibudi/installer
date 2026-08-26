const std = @import("std");

pub fn build(b: *std.Build) void {
    const init = b.addExecutable(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/init.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux }),
            .optimize = .ReleaseSmall,
        }),
    });

    // Runs on the build machine, so it links libarchive rather than carrying
    // a newc encoder of our own.
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

    const qemu = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M",
        "q35",
        "-m",
        "512",
        "-nographic",
        "-no-reboot",
        "-append",
        "console=ttyS0",
    });
    qemu.addArg("-kernel");
    qemu.addFileArg(kernel);
    qemu.addArg("-initrd");
    qemu.addFileArg(initramfs);
    qemu.addArg("-drive");
    // -drive options are order-independent, so putting file= last lets the
    // whole thing be one argument.
    qemu.addPrefixedFileArg("if=virtio,format=raw,file=", scratchDisk(b));
    qemu.has_side_effects = true;

    b.step("qemu", "boot the initramfs and print what init says")
        .dependOn(&qemu.step);
}

/// Something for the installer to find. qemu-img ships with the qemu this
/// step already needs.
fn scratchDisk(b: *std.Build) std.Build.LazyPath {
    const create = b.addSystemCommand(&.{ "qemu-img", "create", "-f", "raw" });
    const img = create.addOutputFileArg("disk.img");
    create.addArg("256M");
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
    // The only paths the build graph knows and mkcpio cannot. What goes in
    // the archive is mkcpio's own business.
    run.addArtifactArg(init);
    run.addDirectoryArg(modules);
    return initramfs;
}
