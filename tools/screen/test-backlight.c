/* Host-side check for the brightness state machine in changxing60-screen.c.
 *
 * The power-key path cannot be exercised on the host any other way: --dump returns before the
 * backlight is touched, and the real path needs /dev/dri/card0 and a writable
 * /sys/class/backlight entry, neither of which exists off the device. The state file is the part
 * worth pinning down -- a level that comes back wrong after a reboot is exactly the bug this
 * feature was added to remove, and it is silent. Not part of the device build.
 *
 *   usage: test-backlight        (exit 0 = all checks passed)
 *
 * The whole program is compiled in, with its main() renamed, so the test drives the real
 * handle_key()/backlight_load()/backlight_save() rather than a copy of them.
 */
#define main changxing60_screen_main
#include "changxing60-screen.c"
#undef main

static const char *state = "/tmp/changxing60-bl-test/backlight";
static int fails;

static void expect(int got, int want, const char *what)
{
	if (got != want) { fprintf(stderr, "FAIL %-28s got %d want %d\n", what, got, want); fails++; }
	else fprintf(stderr, "ok   %-28s %d\n", what, got);
}

/* Put CONTENTS in the state file (NULL removes it) and point the program at it. */
static void state_file(const char *contents)
{
	mkdir("/tmp/changxing60-bl-test", 0755);
	strcpy(bl_state, state);
	if (!contents) { unlink(state); return; }
	FILE *f = fopen(state, "w");
	if (!f) { perror("state_file"); exit(2); }
	fputs(contents, f);
	fclose(f);
}

/* What the program's value is after reading the state file. */
static void load(void)
{
	bl_index = 0;                  /* what a fresh process starts at */
	backlight_load();
}

/* The number currently stored, or -1 if there is no usable file. */
static int stored(void)
{
	FILE *f = fopen(state, "r");
	int v = -1;
	if (!f) return -1;
	if (fscanf(f, "%d", &v) != 1) v = -1;
	fclose(f);
	return v;
}

int main(void)
{
	/* No state file (first boot after the update): full brightness, never dark. */
	state_file(NULL);
	load();
	expect(bl_levels[bl_index], 100, "no file -> full brightness");

	/* Every step survives the round trip, and screen_on follows the step. */
	for (int i = 0; i < BL_N; i++) {
		char what[64];
		state_file(NULL);
		bl_index = i;
		backlight_apply();
		int on = screen_on;
		backlight_save();
		load();
		snprintf(what, sizeof what, "step %d saved", bl_levels[i]);
		expect(bl_levels[bl_index], bl_levels[i], what);
		snprintf(what, sizeof what, "step %d screen_on", bl_levels[i]);
		expect(on, bl_levels[i] > 0, what);
		/* the file is meant to be human-readable: a bare number, no units */
		snprintf(what, sizeof what, "step %d bare number", bl_levels[i]);
		expect(stored(), bl_levels[i], what);
	}

	/* One press steps down; from "off" it wraps back to full, so the key can never get stuck
	 * on a dark screen. */
	state_file(NULL);
	bl_index = 0;
	handle_key(KEY_POWER, 1);
	expect(bl_levels[bl_index], 75, "press from full -> 75");
	expect(stored(), 75, "press is persisted");
	bl_index = BL_N - 1;                                  /* off */
	handle_key(KEY_POWER, 1);
	expect(bl_levels[bl_index], 100, "press from off wraps to full");
	expect(screen_on, 1, "wrap turns the backlight back on");

	/* Releases and autorepeat must not move it: a held key would otherwise race through the
	 * cycle, and gpio-keys does emit autorepeat. */
	state_file(NULL);
	bl_index = 0;
	handle_key(KEY_POWER, 0);
	handle_key(KEY_POWER, 2);
	expect(bl_levels[bl_index], 100, "release/autorepeat ignored");

	/* A level the cycle cannot reach is refused rather than adopted, and vice versa for the
	 * volume keys, which step one at a time and stop at the ends. */
	state_file("7\n");
	load();
	expect(bl_levels[bl_index], 100, "unknown saved level -> default");
	state_file("25\n");
	load();
	expect(bl_levels[bl_index], 25, "saved level is honoured");
	handle_key(KEY_VOLUMEUP, 1);
	expect(bl_levels[bl_index], 50, "volume up -> brighter");
	handle_key(KEY_VOLUMEDOWN, 1);
	expect(bl_levels[bl_index], 25, "volume down -> dimmer");
	handle_key(KEY_VOLUMEDOWN, 1);
	expect(bl_levels[bl_index], 0, "volume down again -> off");
	handle_key(KEY_VOLUMEDOWN, 1);
	expect(bl_levels[bl_index], 0, "volume down stops at off");
	bl_index = 0;
	handle_key(KEY_VOLUMEUP, 1);
	expect(bl_levels[bl_index], 100, "volume up stops at full");

	/* An empty file (a crash between open and write) is not a level. */
	state_file("");
	load();
	expect(bl_levels[bl_index], 100, "empty file -> default");

	/* --- idle blank ---------------------------------------------------------------
	 * The page goes dark once nobody has pressed a key for a while, and comes back at the step
	 * it was left on. The dangerous part is what it must NOT do: change the remembered step,
	 * rewrite the state file, or swallow the first press after waking. */
	state_file("100\n");
	load();
	bl_idle_s = 60;
	bl_idle_dark = 0;
	bl_idle_seen = time(NULL) - 10;                 /* not yet */
	idle_tick();
	expect(bl_idle_dark, 0, "idle: not dark before the timeout");
	bl_idle_seen = time(NULL) - 61;                 /* overdue */
	idle_tick();
	expect(bl_idle_dark, 1, "idle: dark after the timeout");
	expect(bl_levels[bl_index], 100, "idle: step unchanged");
	expect(stored(), 100, "idle: state file unchanged");
	expect(screen_on, 1, "idle: screen_on unchanged (step is not off)");

	/* The waking press restores the page and does NOT step the brightness down. */
	handle_key(KEY_POWER, 1);
	expect(bl_idle_dark, 0, "wake: back on");
	expect(bl_levels[bl_index], 100, "wake: step not changed by the waking press");
	expect(stored(), 100, "wake: state file still unchanged");
	/* ...and the press after that behaves normally. */
	handle_key(KEY_POWER, 1);
	expect(bl_levels[bl_index], 75, "wake: next press steps normally");

	/* A step of "off" chosen by the user is already dark; the timer must not fight it, and it
	 * must not claim credit for it either. */
	bl_index = BL_N - 1;
	bl_idle_dark = 0;
	bl_idle_seen = time(NULL) - 1000;
	idle_tick();
	expect(bl_idle_dark, 0, "idle: user's own off is left alone");

	/* Disabled (the shipped default) means the timer never fires. */
	bl_idle_dark = 0;
	bl_idle_s = 0;
	bl_index = 0;
	bl_idle_seen = time(NULL) - 100000;
	idle_tick();
	expect(bl_idle_dark, 0, "idle: 0 disables the timer");

	/* idle_config() reads the file and the environment, and the environment wins. */
	mkdir("/tmp/changxing60-bl-test", 0755);
	FILE *cf = fopen("/tmp/changxing60-bl-test/panel-idle", "w");
	if (cf) { fputs("120\n", cf); fclose(cf); }
	bl_idle_s = 0;
	idle_config();                                  /* no env: todo-> the file is not where the code looks */
	expect(bl_idle_s, 0, "idle: /etc path not shadowed by the test");
	putenv((char *)"CHANGXING60_PANEL_IDLE=45");
	bl_idle_s = 0;
	idle_config();
	expect(bl_idle_s, 45, "idle: env override honoured");
	/* An explicit 0 is authoritative off -- and it has to win even when the file above asked for
	 * 120 s, or there is no way to disable the timer without editing the file first. */
	putenv((char *)"CHANGXING60_PANEL_IDLE=0");
	bl_idle_s = 7;
	idle_config();
	expect(bl_idle_s, 0, "idle: env 0 turns it off even so");
	bl_idle_s = 0;

	if (fails) fprintf(stderr, "%d FAILED\n", fails);
	else fprintf(stderr, "all passed\n");
	return fails ? 1 : 0;
}
