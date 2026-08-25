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

    const kernel = b.dependency("linux", .{}).namedLazyPath("vmlinuz");
    const initramfs = buildInitramfs(b, init);

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

const cpio_script =
    \\set -eu
    \\stage=$(mktemp -d)
    \\trap 'rm -rf "$stage"' EXIT
    \\cp "$1" "$stage/init"
    \\(cd "$stage" && find . | cpio -o -H newc 2>/dev/null) > "$2"
;

fn buildInitramfs(b: *std.Build, init: *std.Build.Step.Compile) std.Build.LazyPath {
    const cpio = b.addSystemCommand(&.{ "sh", "-c", cpio_script, "cpio_script" });
    cpio.addArtifactArg(init);
    return cpio.addOutputFileArg("initramfs.cpio");
}
