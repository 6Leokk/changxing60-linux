/* Host-side check for the call page in changxing60-screen.c.
 *
 * Two things on that page are silent failures on the device, and both are the kind you only notice
 * when it matters:
 *
 *   - the key mapping. "volume up answers, volume down hangs up, and only while a call is up" is a
 *     rule about which of three keys does what in which of six call states. Getting it wrong means
 *     a key that dims the screen when somebody is trying to answer, or a volume key that hangs up a
 *     call nobody made. Neither is visible on a bench.
 *   - reading the state file. The daemon writes it; this reads it. A field parsed off by one byte
 *     shows the wrong number, or shows nothing at all, on the one screen whose entire job is the
 *     number.
 *
 * Not part of the device build. The whole program is compiled in, with its main() renamed, so the
 * test drives the real read_voice()/handle_key()/idle_tick() rather than a copy of them.
 *
 *   usage: test-call        (exit 0 = all checks passed)
 */
#define main changxing60_screen_main
#include "changxing60-screen.c"
#undef main

static int fails;

static void check(int cond, const char *what)
{
	if (cond) fprintf(stderr, "ok   %s\n", what);
	else { fprintf(stderr, "FAIL %s\n", what); fails++; }
}

static void eqs(const char *got, const char *want, const char *what)
{
	if (strcmp(got, want) == 0) fprintf(stderr, "ok   %-34s %s\n", what, got);
	else { fprintf(stderr, "FAIL %-34s got [%s] want [%s]\n", what, got, want); fails++; }
}

static void eql(long long got, long long want, const char *what)
{
	if (got == want) fprintf(stderr, "ok   %-34s %lld\n", what, got);
	else { fprintf(stderr, "FAIL %-34s got %lld want %lld\n", what, got, want); fails++; }
}

/* Point the program at a state file of our own, and at a brightness file that is not the device's.
 * TMPDIR because the build image's /tmp is root-owned and this test is not run as root. */
static void state_file(const char *contents)
{
	const char *d = getenv("TMPDIR");
	char dir[64], path[80];
	if (!d || !*d) d = "/tmp";
	snprintf(dir, sizeof dir, "%s/changxing60-call-test", d);
	snprintf(path, sizeof path, "%s/state", dir);
	if (mkdir(dir, 0755) < 0 && errno != EEXIST) { perror(dir); exit(2); }
	snprintf(vc_state_file, sizeof vc_state_file, "%s", path);
	snprintf(bl_state, sizeof bl_state, "%s/backlight", dir);
	if (!contents) { unlink(path); return; }
	FILE *f = fopen(path, "w");
	if (!f) { perror(path); exit(2); }
	fputs(contents, f);
	fclose(f);
}

/* A state file as changxing60-voiced writes it. */
static void state(const char *st, const char *dir, const char *num, const char *name, long long since, long long talk)
{
	char b[512], tk[32];
	if (talk) snprintf(tk, sizeof tk, "%lld", talk); else tk[0] = 0;   /* the daemon leaves it empty */
	snprintf(b, sizeof b,
		"state=%s\ndir=%s\nnumber=%s\nname=%s\nidx=1\nsince=%lld\ntalk=%s\nupdated=%lld\n",
		st, dir, num, name, since, tk, since);
	state_file(b);
	read_voice();
}

/* A key press, with the CLI stubbed out (CHANGXING60_SCREEN_DRYRUN makes voice_cmd_run only record). */
static void press(__u16 code)
{
	vc_last_cmd[0] = 0;
	handle_key(code, 1);
}

int main(void)
{
	setenv("CHANGXING60_SCREEN_DRYRUN", "1", 1);

	fprintf(stderr, "== reading the state file ==\n");
	state_file(NULL);
	read_voice();
	eqs(vc_state, "idle", "no file at all is no call");
	check(!voice_active(), "no file: not active");

	state("ringing", "in", "+8613800138000", "Zhang Wei", 1700000000, 0);
	eqs(vc_state, "ringing", "state");
	eqs(vc_dir, "in", "dir");
	eqs(vc_number, "+8613800138000", "number");
	eqs(vc_name, "Zhang Wei", "name");
	eql(vc_since, 1700000000, "since");
	eql(vc_talk, 0, "talk while ringing is empty");
	check(voice_active(), "ringing: active");

	state("active", "out", "10086", "", 1700000000, 1700000042);
	eqs(vc_state, "active", "state");
	eqs(vc_dir, "out", "dir");
	eql(vc_talk, 1700000042, "talk once answered");
	eqs(vc_name, "", "an unknown caller has no name");

	/* A field the daemon did not write is empty, not garbage from the line before it. */
	state_file("state=held\ndir=in\n");
	read_voice();
	eqs(vc_state, "held", "a short file still parses");
	eqs(vc_number, "", "a missing key reads as empty");
	eql(vc_since, 0, "a missing number reads as zero");

	fprintf(stderr, "\n== the header word ==\n");
	state("ringing", "in", "10086", "", 1700000000, 0);
	eqs(call_headline(), "incoming", "ringing in");
	state("ringing", "out", "10086", "", 1700000000, 0);
	eqs(call_headline(), "ringing", "ringing out is not \"incoming\"");
	state("active", "out", "10086", "", 1700000000, 1700000042);
	eqs(call_headline(), "out call", "active out");
	state("active", "in", "10086", "", 1700000000, 1700000042);
	eqs(call_headline(), "in call", "active in");
	state("held", "in", "10086", "", 1700000000, 1700000042);
	eqs(call_headline(), "on hold", "held");

	fprintf(stderr, "\n== duration ==\n");
	char d[24];
	fmt_dur(0, d, sizeof d);    eqs(d, "00:00", "zero");
	fmt_dur(83, d, sizeof d);   eqs(d, "01:23", "under an hour");
	fmt_dur(3600, d, sizeof d); eqs(d, "1:00:00", "exactly an hour");
	fmt_dur(-5, d, sizeof d);   eqs(d, "00:00", "a clock that went backwards");

	fprintf(stderr, "\n== the keys, while a call is up ==\n");
	bl_index = 0;
	state("ringing", "in", "+8613800138000", "", 1700000000, 0);
	press(KEY_VOLUMEUP);
	eqs(vc_last_cmd, "answer", "volume up answers a ringing call");
	eql(bl_index, 0, "...and does not touch the brightness");

	press(KEY_VOLUMEDOWN);
	eqs(vc_last_cmd, "hangup", "volume down hangs up a ringing call");
	eql(bl_index, 0, "...and does not touch the brightness");

	/* The press that answers must be the answer even when the panel is dark. */
	bl_idle_dark = 1;
	press(KEY_VOLUMEUP);
	eqs(vc_last_cmd, "answer", "a dark panel does not swallow the answer");
	eql(bl_idle_dark, 1, "...and the wake-up branch is not what ran");
	bl_idle_dark = 0;

	/* Mid-call there is nothing to answer, so volume up goes back to being a brightness key. */
	bl_index = 2;
	state("active", "in", "+8613800138000", "", 1700000000, 1700000042);
	press(KEY_VOLUMEUP);
	eqs(vc_last_cmd, "", "volume up mid-call does not answer");
	eql(bl_index, 1, "volume up mid-call is still brightness");

	press(KEY_VOLUMEDOWN);
	eqs(vc_last_cmd, "hangup", "volume down mid-call hangs up");
	eql(bl_index, 1, "...and does not also change the brightness");

	/* The power key is never the call's: a long press is the PMIC's power-off and must stay so. */
	bl_index = 0;
	press(KEY_POWER);
	eqs(vc_last_cmd, "", "power is not a call control");
	eql(bl_index, 1, "power still cycles the brightness");

	fprintf(stderr, "\n== the keys, with no call ==\n");
	bl_index = 2;
	state("idle", "", "", "", 0, 0);
	press(KEY_VOLUMEUP);
	eqs(vc_last_cmd, "", "volume up with no call is not an answer");
	eql(bl_index, 1, "volume up with no call is brightness");
	press(KEY_VOLUMEDOWN);
	eql(bl_index, 2, "volume down with no call is brightness");
	press(KEY_POWER);
	eql(bl_index, 3, "power with no call is brightness");

	/* A release and an autorepeat are not presses. */
	bl_index = 0;
	vc_last_cmd[0] = 0;
	handle_key(KEY_VOLUMEUP, 0);
	handle_key(KEY_VOLUMEUP, 2);
	eql(bl_index, 0, "release and autorepeat do nothing");
	eqs(vc_last_cmd, "", "...and command nothing");

	fprintf(stderr, "\n== the panel stays lit for a call ==\n");
	bl_index = 0;                    /* full brightness: the state the idle timer is allowed to darken */
	bl_idle_s = 10;
	bl_idle_dark = 0;
	bl_idle_seen = time(NULL) - 60;  /* idle for a minute */
	state("idle", "", "", "", 0, 0);
	idle_tick();
	check(bl_idle_dark, "no call: the idle timer darkens the panel");

	bl_idle_dark = 0;
	bl_idle_seen = time(NULL) - 60;
	state("ringing", "in", "+8613800138000", "", time(NULL), 0);
	idle_tick();
	check(!bl_idle_dark, "a call keeps the panel lit past the idle timeout");

	bl_idle_dark = 0;
	bl_idle_seen = time(NULL) - 60;
	state("active", "in", "+8613800138000", "", time(NULL), time(NULL));
	idle_tick();
	check(!bl_idle_dark, "a call in progress keeps it lit too");

	fprintf(stderr, "\n%s (%d failure%s)\n", fails ? "FAILURES" : "all passed", fails, fails == 1 ? "" : "s");
	return fails != 0;
}
