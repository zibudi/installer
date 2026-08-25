const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });

    // No libc: std talks to the kernel directly, so the binary owes the
    // initramfs nothing but itself.
    const init = b.addExecutable(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/init.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .link_libc = false,
        }),
    });

    const kernel = b.dependency("linux", .{}).namedLazyPath("vmlinuz");
    const initramfs = buildInitramfs(b, init);

    b.getInstallStep().dependOn(&b.addInstallFile(kernel, "vmlinuz").step);
    b.getInstallStep().dependOn(&b.addInstallFile(initramfs, "initramfs.cpio").step);

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

// /dev is empty but must exist: init mounts devtmpfs onto it to get a console.
const cpio_script =
    \\set -eu
    \\stage=$(mktemp -d)
    \\trap 'rm -rf "$stage"' EXIT
    \\mkdir -p "$stage/dev"
    \\cp "$1" "$stage/init"
    \\chmod 755 "$stage/init"
    \\(cd "$stage" && find . | cpio -o -H newc 2>/dev/null) > "$2"
;

fn buildInitramfs(b: *std.Build, init: *std.Build.Step.Compile) std.Build.LazyPath {
    const cpio = b.addSystemCommand(&.{ "sh", "-c", cpio_script, "cpio_script" });
    cpio.addArtifactArg(init);
    return cpio.addOutputFileArg("initramfs.cpio");
}
