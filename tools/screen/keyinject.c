// SPDX-License-Identifier: GPL-2.0
/*
 * Emit synthetic key presses through /dev/input/uinput, to prove the panel's key handling end to
 * end without a finger on the button. The GPIO key itself cannot be pressed from software, but
 * everything downstream of it can: this creates a virtual input device carrying the same key
 * codes the device tree gives gpio-keys (116 = KEY_POWER, 114/115 = the volume rocker) and then
 * presses them on a timer.
 *
 * The reader opens every /dev/input/event* once at startup, so the virtual device has to exist
 * *before* it starts -- hence the leading sleep, which is also what makes the sequence easy to
 * observe from outside: start this, start the reader, and watch the backlight alternate.
 *
 *   usage: keyinject [keycode] [count] [gap-seconds]
 *   default: KEY_POWER, 4 presses, 3 s apart
 */
#include <linux/uinput.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>

static void emit(int fd, int type, int code, int val)
{
	struct input_event ev;

	memset(&ev, 0, sizeof ev);
	ev.type = type;
	ev.code = code;
	ev.value = val;
	if (write(fd, &ev, sizeof ev) != (ssize_t)sizeof ev)
		perror("write");
}

int main(int argc, char **argv)
{
	int code = KEY_POWER;
	int count = 4;
	int gap_s = 3;

	if (argc > 1) code = atoi(argv[1]);
	if (argc > 2) count = atoi(argv[2]);
	if (argc > 3) gap_s = atoi(argv[3]);

	int fd = open("/dev/input/uinput", O_WRONLY | O_NONBLOCK);
	if (fd < 0) { perror("open /dev/input/uinput"); return 1; }

	if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
	    ioctl(fd, UI_SET_EVBIT, EV_SYN) < 0 ||
	    ioctl(fd, UI_SET_KEYBIT, code) < 0) {
		perror("uinput setup");
		return 1;
	}

	struct uinput_setup usetup;

	memset(&usetup, 0, sizeof usetup);
	usetup.id.bustype = BUS_VIRTUAL;
	usetup.id.vendor = 0x1d5c;
	usetup.id.product = 0x3000;
	snprintf(usetup.name, UINPUT_MAX_NAME_SIZE, "changxing60-keyinject");
	if (ioctl(fd, UI_DEV_SETUP, &usetup) < 0) { perror("UI_DEV_SETUP"); return 1; }
	if (ioctl(fd, UI_DEV_CREATE) < 0) { perror("UI_DEV_CREATE"); return 1; }
	printf("keyinject: created, will send %d press(es) of key %d every %d s\n",
	       count, code, gap_s);
	fflush(stdout);

	for (int i = 0; i < count; i++) {
		sleep(gap_s);
		emit(fd, EV_KEY, code, 1);
		emit(fd, EV_SYN, SYN_REPORT, 0);
		usleep(80000);                       /* release well inside the reader's 150 ms
						      * debounce window, so one cycle counts once */
		emit(fd, EV_KEY, code, 0);
		emit(fd, EV_SYN, SYN_REPORT, 0);
		printf("keyinject: press %d\n", i + 1);
		fflush(stdout);
	}

	sleep(1);
	ioctl(fd, UI_DEV_DESTROY);
	close(fd);
	return 0;
}
