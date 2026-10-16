/*
 * changxing60-modemd: the CP log daemon's part in a CP reset.
 *
 * Ported from e5-linux (device/openwrt_device_common/src/e5-modemd.c), which is the same
 * Unisoc vendor stack on a sibling SoC. The protocol is not assumed to be the same -- it was
 * checked against this board's own /vendor/bin/modem_control before a line of this was written:
 *
 *   * the binary imports socket_local_server and passes it "modemd", namespaceId 0, SOCK_STREAM
 *     (call site 0x7874 in modem_control; libcutils' socket_make_sockaddr_un turns w1==0 into
 *     sun_path[0]='\0' + the name, i.e. the abstract namespace);
 *   * it contains the strings "SLOGMODEM DUMP COMPLETE" and, verbatim,
 *     "reset_md_thread wait dump complete...";
 *   * it accepts clients and logs "%s: client cnct to modemd num = %d, buf = %s".
 *
 * So modem_control is the server: it sends its clients the modem's state as text ("Modem Assert",
 * "Modem Reset", "Modem Alive"), and after an assert it waits for "SLOGMODEM DUMP COMPLETE" from
 * the CP log daemon before it resets the CP. Android's log daemon sends that once it has saved the
 * dump; nothing does on this board, so every assert costs modem_control's full 300 s timeout and
 * the WAN stays down for all of it. This client answers every assert at once -- no dump is kept --
 * and logs the state messages.
 *
 * THAT 300 s SAVING IS NOT DEMONSTRATED ON THIS BOARD, and the reason is now known. Disassembly of
 * this board's own modem_control shows the state strings are written to a client fd in exactly one
 * place, immediately after accept() (the fill, logged "fill<fd> to client[<slot>]"). Later
 * transitions go out through process_message() (0x6ea0), which broadcasts to every client in the
 * 20-slot table at 0x14790 -- but the assert path only broadcasts when the AP-side state variable
 * (0x147e0) is 1, and process_message sets it to 1 only for a message containing "Modem Alive".
 * Here it never gets there: the fill a client receives on connect says "Modem State: Offline", so
 * the variable is 0 and that == 1 gate never opens. Two on-device observations agree -- with this
 * client connected, neither a real CP assert (smsg.c line 168) nor a changxing60-vendor restart
 * produced a byte after the connect fill, while the WAN stayed up throughout. So the client is
 * inert here, not broken: it costs nothing, it records the state on connect, and it starts working
 * the moment anything makes modem_control believe the modem is alive.
 *
 * The vendor RIL also tells modem_control when the CP's AT server stops answering, with "Modem
 * Blocked"; on e5 modem_control then resets the CP once the dump is done, so e5 documents
 * `e5-modemd blocked` as a CP reset on demand. DO NOT USE IT THAT WAY ON THIS BOARD. It was tried
 * here, once, on a healthy link, and this is what happened (all of it from modem_control's own log
 * on the logd bridge, and from /sys/kernel/debug/modem/modem):
 *
 *   modem_ctrl_listen_clients: read cnt= 14, str= Modem Blocked
 *   modem_ctrl_listen_modem: read Modem Assert:  PS CP assert in file smsg.c line 168 ...
 *
 * The message was read, and in the same second the CP asserted, the SIPA data path tore down, and
 * the AT channel went silent. run_state stayed 1, so modem_control never reset the CP; it went back
 * to waiting. A CP stop/start through /dev/modem -- which is what mobile-data's own last resort does
 * -- did not bring it back either, and only a reboot did. Whether the message caused the assert or
 * merely coincided with one is NOT established: the CP has asserted on its own on this board before.
 * Either way the verb is not safe to put on an automatic path, so it is kept as a diagnostic only,
 * and the recovery path for a wedged modem stays what it was.
 *
 *   changxing60-modemd            connect (retrying), then serve until the socket closes
 *   changxing60-modemd blocked    send "Modem Blocked" and exit -- see the warning above
 *
 * WHY THIS CLIENT HAD TO WAIT FOR A FIX ELSEWHERE. modem_control only creates the socket at all
 * when ro.vendor.radio.modemtype reads as something other than "not_find" (predicate at 0xbc60,
 * whose result gates the pthread_create at 0x6390). Every property read on this board used to
 * return the caller's default, because the property area under /dev/__properties__ was owned by
 * uid 1000 and bionic's PropertyInfoAreaFile::LoadPath refuses anything that is not root:root.
 * android-vendor-start now chowns it, the property reads "nr", and the socket exists. This client
 * still retries rather than failing, so it is also correct on a board where that is not yet true
 * -- and it says so, once, instead of spinning silently.
 *
 * WHAT IS NOT DONE HERE. A real CP dump would mean saving /dev/slog_nr (ro.vendor.modem.log)
 * before answering. That is the Android log daemon's job and is not attempted: answering at once
 * costs us no dump we would otherwise have had, because with no client at all modem_control times
 * out and resets without a dump anyway. The trade is 300 s of dead WAN against a dump we never got.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#ifndef SOCKET_NAME
#define SOCKET_NAME "modemd"
#endif
#define DUMP_COMPLETE "SLOGMODEM DUMP COMPLETE"
#define MODEM_BLOCKED "Modem Blocked"

/* The state messages are stream data: read boundaries are not message boundaries. The vendor frames
 * each one with a NUL -- what a client is sent on connect is exactly
 *
 *     "Modem State: Offline\0CH State: CH OFFLINE\0"
 *
 * (read off this board's own modem_control with a raw client, not taken from e5), so a message is the
 * bytes up to a NUL and the two fields describe the same state from the AP and the CP side. A stream
 * with no NUL at all would otherwise never be looked at, so an overlong message is flushed as if the
 * NUL had arrived rather than growing a buffer to hold whatever the vendor sends next.
 */
struct state_reader {
	char msg[192];
	size_t used;
};

/* The log is the only record of a CP reset: the console is pinned to ERR and above (quiet-console
 * sets 4 4 1 4), and a modem_control state message is not a kernel error, so nothing about this
 * reaches the console or pstore. It goes to stdout for procd (which is bridged to logd by logdw)
 * and to a file, because a daemon that is restarted by procd after a reset has no stdout history.
 */
#define LOGFILE "/root/changxing60-modemd.log"
#define LOGMAX (256 * 1024)

static void logline(const char *fmt, ...)
	__attribute__((format(printf, 1, 2)));

static void logline(const char *fmt, ...)
{
	char body[512];
	char line[600];
	va_list ap;
	time_t now;
	struct tm tm;
	int fd;
	size_t n;

	va_start(ap, fmt);
	vsnprintf(body, sizeof(body), fmt, ap);
	va_end(ap);

	now = time(NULL);
	localtime_r(&now, &tm);
	n = (size_t)snprintf(line, sizeof(line), "%04d-%02d-%02d %02d:%02d:%02d %s\n",
			     tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
			     tm.tm_hour, tm.tm_min, tm.tm_sec, body);

	fputs(line, stdout);
	fflush(stdout);

	fd = open(LOGFILE, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
	if (fd < 0)
		return;
	/* A daemon that runs for months must not fill the rootfs with "Modem Alive". The cap is
	 * checked before the write, so the file can overshoot by one line and no more. */
	if (lseek(fd, 0, SEEK_END) > LOGMAX && ftruncate(fd, 0) == 0)
		lseek(fd, 0, SEEK_END);
	/* Best effort: the log is a convenience, and stdout has already carried the line. A write
	 * that fails (a full rootfs, most likely) must not take the daemon down with it -- this is
	 * the process that decides how long the WAN stays dead after an assert. */
	(void)!write(fd, line, n);
	close(fd);
}

static int send_all(int fd, const char *message, size_t size)
{
	while (size) {
		ssize_t n = send(fd, message, size, MSG_NOSIGNAL);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return -1;
		message += n;
		size -= n;
	}
	return 0;
}

static int answer_dump(int fd)
{
	if (send_all(fd, DUMP_COMPLETE, sizeof(DUMP_COMPLETE)) < 0) {
		logline("could not answer the dump request: %s", strerror(errno));
		return -1;
	}
	logline("sent \"%s\" (CP dump skipped, the reset may go ahead)", DUMP_COMPLETE);
	return 0;
}

/* A line a person would recognise as a state, as opposed to a slice of a CP dump. Only used to decide
 * whether an unrecognised message is worth printing. */
static int looks_like_state(const char *s)
{
	size_t n = strlen(s);
	if (n == 0 || n > 128)
		return 0;
	for (size_t i = 0; i < n; i++) {
		unsigned char c = (unsigned char)s[i];
		if (c < 0x20 || c > 0x7e)
			return 0;
	}
	return 1;
}

/* Every token modem_control can say, taken from the strings in this board's own /vendor/bin/modem_control
 * rather than from e5's table: e5's list has no "Modem State: Offline" and no CH-state field at all, and
 * a client that matches none of what it is told is indistinguishable from one that is told nothing.
 * The bare forms are matched as substrings on purpose -- the CP's own assert text arrives inside a
 * longer line ("Modem Assert: modem not alive!", "P-ARM Modem Assert") and all of them are asserts.
 *
 * Both fields of one event are answered. modem_control sends the AP's view and the CP's view as two
 * messages ("Modem State: Assert" then "CH State: CH Assert"), so an assert is acknowledged twice; the
 * acknowledgement is a statement that the dump is done, which is true either way. e5's client does the
 * same and its resets were measured at 4-5 s, so this is not a change worth inventing a guard for.
 */
static int handle_message(struct state_reader *r, int fd)
{
	static const struct { const char *name; int dump; } events[] = {
		{"Modem State: Assert", 1}, {"Modem State: Blocked", 1},
		{"Modem State: Reset", 0},  {"Modem State: Alive", 0},
		{"Modem State: Offline", 0},
		{"Modem Assert", 1}, {"Modem Blocked", 1},
		{"Modem Reset", 0},  {"Modem Alive", 0},
		{"CH State: CH Assert", 1}, {"CH State: CH Reset", 0},
		{"CH State: CH Alive", 0},  {"CH State: CH OFFLINE", 0},
		{"CH State: CH Unknown", 0},
	};
	int matched = 0;

	r->msg[r->used] = '\0';
	if (r->used == 0)
		return 0;

	for (size_t e = 0; e < sizeof(events) / sizeof(events[0]); e++) {
		if (!strstr(r->msg, events[e].name))
			continue;
		matched = 1;
		logline("%s", events[e].name);
		if (events[e].dump && answer_dump(fd) < 0)
			return -1;
	}
	/* Anything the table does not know is printed rather than dropped. This log is the only record
	 * of what modem_control said -- the console is pinned to ERR and above and a state message is
	 * not a kernel error -- and a client that silently ignores a message cannot be told apart from
	 * one that was never spoken to. That is not hypothetical: the first version of this file kept
	 * only a rolling suffix and matched nothing at all, and it looked exactly like an idle modem.
	 * The shape check keeps a CP dump, which arrives on the same socket, out of the log. */
	if (!matched && looks_like_state(r->msg))
		logline("(unrecognised) %s", r->msg);
	r->used = 0;
	return 0;
}

static int read_states(struct state_reader *r, int fd, const char *data, size_t size)
{
	for (size_t i = 0; i < size; i++) {
		if (data[i] == '\0') {
			if (handle_message(r, fd) < 0)
				return -1;
			continue;
		}
		if (r->used == sizeof(r->msg) - 1 && handle_message(r, fd) < 0)
			return -1;
		r->msg[r->used++] = data[i];
	}
	return 0;
}

static int connect_modemd(void)
{
	struct sockaddr_un addr;
	socklen_t len;
	int fd;

	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	/* abstract namespace: a leading NUL, no terminator (bionic's socket_local_server with
	 * ANDROID_SOCKET_NAMESPACE_RESERVED, which is what modem_control calls -- see the header) */
	memcpy(addr.sun_path + 1, SOCKET_NAME, strlen(SOCKET_NAME));
	len = offsetof(struct sockaddr_un, sun_path) + 1 + strlen(SOCKET_NAME);
	if (connect(fd, (struct sockaddr *)&addr, len) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: changxing60-modemd [blocked]\n"
		"  (no argument)  serve modem_control: answer CP asserts so it resets at once\n"
		"  blocked        tell modem_control the CP's AT server is stuck, so it resets the CP\n");
}

int main(int argc, char **argv)
{
	char buf[1024];
	int fd, n, waited = 0;
	struct state_reader reader = {0};

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc > 1) {
		if (argc != 2 || strcmp(argv[1], "blocked")) {
			usage();
			return 2;
		}
		fd = connect_modemd();
		if (fd < 0 || send_all(fd, MODEM_BLOCKED, sizeof(MODEM_BLOCKED)) < 0) {
			/* The caller is usually a script deciding whether to reset the CP; the
			 * reason it could not is the whole value of the message, so print errno
			 * rather than a bare failure. errno is set by connect when fd < 0 and by
			 * send otherwise, so one strerror covers both. */
			fprintf(stderr, "changxing60-modemd: modemd: %s\n", strerror(errno));
			if (fd >= 0)
				close(fd);
			return 1;
		}
		logline("sent \"%s\"", MODEM_BLOCKED);
		close(fd);
		return 0;
	}

	/* modem_control may not have made the socket yet -- and on this board it did not make it at
	 * all until android-vendor-start started chowning the property area to root (see the header).
	 * Waiting is the point: an assert that happens while we are waiting is still answered, and the
	 * alternative (exit and let procd respawn us) is the same loop with more noise. */
	while ((fd = connect_modemd()) < 0) {
		if (!waited++)
			logline("waiting for modem_control's modemd socket");
		sleep(1);
	}
	logline("connected to modemd, serving (pid %d)", (int)getpid());

	for (;;) {
		n = read(fd, buf, sizeof(buf));
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			break;
		if (read_states(&reader, fd, buf, (size_t)n) < 0)
			break;
	}
	logline("modemd closed the socket");
	close(fd);
	/* Exit non-zero so procd restarts us: modem_control may have been restarted, and with it
	 * the socket we were connected to. */
	return 1;
}
