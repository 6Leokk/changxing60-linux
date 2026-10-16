/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * modem-ioctl - issue the Unisoc modem loader's /dev/modem ioctls.
 *
 * The SIPA wedge (docs/changxing60/sipa-wedge.md) is a CP-side latch: the AP's 2 s
 * delegator timeout unlocks the AP's resource-manager state machine, but the CP
 * itself stops answering, so the carrier never comes back and only a full reboot
 * recovered the box. The modem loader exposes a CP stop/start through /dev/modem
 * (drivers/unisoc_platform/modem_loader/sprd_modem_loader.c), which is the
 * subsystem-level recovery we want instead of rebooting:
 *
 *     MODEM_STOP_CMD               _IO('M', 0x0c)  modem_run(modem, 0, 1)
 *     MODEM_START_CMD              _IO('M', 0x0d)  modem_run(modem, 1, 1)
 *     MODEM_UNCONDITIONAL_STOP_CMD _IO('M', 0x12)  modem_run(modem, 0, 0)
 *     MODEM_ASSERT_CMD             _IO('M', 0x0e)  EPERM unless comm=="modem_control"
 *
 * Nothing in the OpenWrt rootfs can issue an ioctl, and there is no aarch64 libc
 * to link against, so this is a freestanding static binary: raw syscalls, no
 * libc, no interpreter. Build with tools/build-modem-ioctl.sh.
 *
 * Exit status: 0 = ioctl returned >= 0, 1 = ioctl failed (-errno printed),
 * 2 = usage error, 3 = could not open /dev/modem.
 */

typedef unsigned long u64;
typedef long i64;
typedef unsigned int u32;

/* aarch64 Linux syscall numbers */
#define SYS_ioctl 29
#define SYS_openat 56
#define SYS_close 57
#define SYS_write 64
#define SYS_exit_group 94
#define AT_FDCWD -100
#define O_RDWR 2

static i64 sc3(i64 n, i64 a, i64 b, i64 c)
{
	register i64 x0 asm("x0") = a;
	register i64 x1 asm("x1") = b;
	register i64 x2 asm("x2") = c;
	register i64 x8 asm("x8") = n;

	asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
	return x0;
}

static void put(const char *s, u64 n)
{
	i64 r;

	do {
		r = sc3(SYS_write, 1, (i64)s, (i64)n);
	} while (r < 0);
}

static void puts(const char *s)
{
	u64 n = 0;

	while (s[n])
		n++;
	put(s, n);
}

/* Signed decimal; 32-bit digits only, so no udivdi3 (no compiler-rt here). */
static void putn(i64 v)
{
	char buf[16];
	int i = 0;
	u32 u;

	if (v < 0) {
		put("-", 1);
		u = (u32)(-v);
	} else {
		u = (u32)v;
	}
	if (!u) {
		put("0", 1);
		return;
	}
	while (u) {
		buf[i++] = (char)('0' + (u % 10u));
		u /= 10u;
	}
	while (i--)
		put(&buf[i], 1);
}

static int streq(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return *a == *b;
}

#define _IO(type, nr) (((type) << 8) | (nr))

struct cmd {
	const char *name;
	unsigned long code;
	const char *note;
};

static const struct cmd cmds[] = {
	{ "stop", _IO('M', 0x0c), "modem_run(0, restrict)" },
	{ "start", _IO('M', 0x0d), "modem_run(1, restrict)" },
	{ "ustop", _IO('M', 0x12), "modem_run(0, no restrict)" },
	{ "assert", _IO('M', 0x0e), "EPERM unless comm==modem_control" },
};

static const char usage[] =
	"usage: modem-ioctl stop|start|ustop|assert\n"
	"  opens /dev/modem, issues one ioctl, prints the return value.\n";

void main_entry(u64 *sp);
__asm__(
	".text\n"
	".globl _start\n"
	"_start:\n"
	"  mov x0, sp\n"		/* argv lives just above the entry sp */
	"  b main_entry\n");

void main_entry(u64 *sp)
{
	char **argv = (char **)&sp[1];
	int argc = (int)sp[0];
	int i, n = (int)(sizeof(cmds) / sizeof(cmds[0]));
	const struct cmd *c = 0;
	i64 fd, ret;

	if (argc < 2) {
		puts(usage);
		sc3(SYS_exit_group, 2, 0, 0);
	}
	for (i = 0; i < n; i++)
		if (streq(argv[1], cmds[i].name))
			c = &cmds[i];
	if (!c) {
		puts("modem-ioctl: unknown command: ");
		puts(argv[1]);
		put("\n", 1);
		puts(usage);
		sc3(SYS_exit_group, 2, 0, 0);
	}

	fd = sc3(SYS_openat, AT_FDCWD, (i64)"/dev/modem", O_RDWR);
	if (fd < 0) {
		puts("modem-ioctl: open /dev/modem: ");
		putn(fd);
		put("\n", 1);
		sc3(SYS_exit_group, 3, 0, 0);
	}

	puts("modem-ioctl: ");
	puts(c->name);
	puts(" (");
	puts(c->note);
	puts(") ... ");
	ret = sc3(SYS_ioctl, fd, (i64)c->code, 0);
	puts("rc=");
	putn(ret);
	put("\n", 1);

	sc3(SYS_close, fd, 0, 0);
	sc3(SYS_exit_group, ret < 0 ? 1 : 0, 0, 0);
}
