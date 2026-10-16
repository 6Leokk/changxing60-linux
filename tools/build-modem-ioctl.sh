#!/bin/bash
# Build tools/modem-ioctl.c into a freestanding static aarch64 binary.
#
# There is no aarch64 libc anywhere here: the rootfs has no compiler, and the
# Ubuntu clang in the changxing60-kbuild image (amd64 host, clang-12) has no aarch64
# sysroot and no libclang_rt.builtins-aarch64.a. So: -nostdlib -static, entry
# point _start, raw syscalls. -fuse-ld=lld is required (host ld is x86_64).
set -e
cd "$(dirname "$0")"
docker run --rm -v "$PWD":/w changxing60-kbuild \
	clang --target=aarch64-linux-gnu -fuse-ld=lld -nostdlib -static -O2 \
	-fno-builtin -fno-stack-protector -fno-asynchronous-unwind-tables \
	-o /w/modem-ioctl /w/modem-ioctl.c
file modem-ioctl
ls -la modem-ioctl
