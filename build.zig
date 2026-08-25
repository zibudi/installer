const std = @import("std");
const Initramfs = @import("tools/Initramfs.zig");

pub fn build(b: *std.Build) void {
    const init = b.addExecutable(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/init.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux }),
            .optimize = .ReleaseSmall,
        }),
    });

    const kernel = b.dependency("linux", .{}).namedLazyPath("vmlinuz");
    const initramfs = Initramfs.create(b, &.{
        .{ .file = .{ .path = "/init", .mode = 0o755, .source = init.getEmittedBin() } },
    }).getOutput();

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
