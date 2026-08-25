# installer

The zibudi installer: one zig program that runs as PID 1.

Right now it says hello and powers off.

## Try it

```sh
zig build qemu
```

Downloads a kernel, builds `init`, packs an initramfs, boots the pair under
QEMU, and prints what init says before the machine powers itself off.

Needs `qemu-system-x86_64`, `curl`, and `cpio` on the host. Nothing else --
zig cross-compiles the Linux binary from whatever you are sitting at.

## What is here

    src/init.zig   PID 1
    build.zig      kernel + initramfs + qemu

`zig build` alone leaves `vmlinuz` and `initramfs.cpio` in `zig-out/`.

## What is borrowed

The kernel is Alpine's `virt` build, fetched at build time from an unversioned
URL. It is a stand-in for a kernel we configure and build ourselves, and it
will change under us whenever Alpine cuts a release.

`cpio` shells out. The archive format is simple enough to emit directly, which
would drop a host dependency and is worth doing before the initramfs grows any
real contents.

Boot is `-kernel`/`-initrd`, which skips firmware entirely. The real path --
GPT, an EFI system partition, and a kernel the firmware loads on its own --
needs an image writer that does not exist yet.
