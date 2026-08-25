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

    // Runs on whatever we are building from, not on the target.
    const mkcpio = b.addExecutable(.{
        .name = "mkcpio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkcpio.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });

    const kernel = b.dependency("linux", .{}).namedLazyPath("vmlinuz");
    const initramfs = buildInitramfs(b, mkcpio, init);

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
    qemu.has_side_effects = true;

    b.step("qemu", "boot the initramfs and print what init says")
        .dependOn(&qemu.step);
}

fn buildInitramfs(
    b: *std.Build,
    mkcpio: *std.Build.Step.Compile,
    init: *std.Build.Step.Compile,
) std.Build.LazyPath {
    const run = b.addRunArtifact(mkcpio);
    const initramfs = run.addOutputFileArg("initramfs.cpio");
    run.addArgs(&.{ "file", "/init", "755" });
    // Passing the binary as its own argument is what makes it a tracked input.
    run.addArtifactArg(init);
    return initramfs;
}
