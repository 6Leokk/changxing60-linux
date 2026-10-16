/* Host-side check for the management address the panel prints as "LuCI http://.../" in
 * mu300-screen.c.
 *
 * This one has a real failure history. The panel used to ask br-lan first, so it printed
 * 192.168.77.1 -- the USB-cable address -- to a reader that had just scanned the Wi-Fi join code
 * printed on the same page and whose only way in was 192.168.8.1 (reported from the device
 * 2026-10-14; the "a hotspot client reaches br-lan too" theory in the old comment did not hold).
 * The address is displayed nowhere else, so getting it wrong is silent until someone tries to open
 * it -- worth pinning down here rather than by squinting at the panel after a flash.
 *
 *   usage: test-lan        (exit 0 = all checks passed)
 *
 * As in test-backlight, the whole program is compiled in with main() renamed, so this drives the
 * real read_wan()/lan_take() against a fake ip(8) that serves whatever the current scenario wrote
 * into $FAKE_IP -- one file per device listing plus "all" for the unfiltered listing.
 */
#define main mu300_screen_main
#include "mu300-screen.c"
#undef main

#include <sys/stat.h>

#define WIFI_LINE "4: br-wifi    inet 192.168.8.1/24 brd 192.168.8.255 scope global br-wifi\n"
#define LAN_LINE  "3: br-lan     inet 192.168.77.1/24 brd 192.168.77.255 scope global br-lan\n"
#define USB_LINE  "5: usb0       inet 192.168.77.1/24 brd 192.168.77.255 scope global usb0\n"
#define WAN_LINE  "9: sipa_eth0  inet 10.44.128.77/30 brd 10.44.128.79 scope global sipa_eth0\n"
#define LO_LINE   "1: lo         inet 127.0.0.1/8 scope host lo\n"

/* The faucet: reads a file named for the invocation out of $FAKE_IP, and prints nothing (but exits
 * 0, as `ip` does for a device that exists with no address) when the scenario left it out. */
static const char *fake_ip =
	"#!/bin/sh\n"
	"case \"$*\" in\n"
	"  \"-4 -o addr show\")       key=all ;;\n"
	"  \"-4 -o addr show dev \"*) key=\"dev-$6\" ;;\n"
	"  *) exit 1 ;;\n"
	"esac\n"
	"[ -f \"$FAKE_IP/$key\" ] || exit 0\n"
	"cat \"$FAKE_IP/$key\"\n";

static const char *dir;
static int fails;

static void put(const char *name, const char *contents)
{
	char p[512];
	FILE *f;
	snprintf(p, sizeof p, "%s/%s", dir, name);
	if (!contents) { unlink(p); return; }
	f = fopen(p, "w");
	if (!f) { perror(p); exit(1); }
	fputs(contents, f);
	fclose(f);
}

static void expect(const char *want, const char *what)
{
	read_wan();
	if (strcmp(lan_ip, want) != 0) {
		fprintf(stderr, "FAIL %-44s got %-14s want %s\n", what, lan_ip, want);
		fails++;
	} else {
		fprintf(stderr, "ok   %-44s %s\n", what, lan_ip);
	}
}

int main(void)
{
	char p[] = "/tmp/mu300-lan-test.XXXXXX";
	FILE *f;

	dir = mkdtemp(p);
	if (!dir) { perror("mkdtemp"); return 1; }

	/* the fake ip(8) goes on PATH ahead of the real one */
	{
		char bin[512];
		snprintf(bin, sizeof bin, "%s/ip", dir);
		f = fopen(bin, "w");
		if (!f) { perror(bin); return 1; }
		fputs(fake_ip, f);
		fclose(f);
		if (chmod(bin, 0755) != 0) { perror("chmod"); return 1; }
		/* ahead of the real one, not instead of it: the fake is a shell script and needs
		 * cat/[ from the rest of PATH to serve its fixtures */
		snprintf(bin, sizeof bin, "%s:%s", dir, getenv("PATH") ? getenv("PATH") : "/bin:/usr/bin");
		setenv("PATH", bin, 1);
		setenv("FAKE_IP", dir, 1);
	}

	/* the panel reads the WAN address out of the same program; give it one so the "not the WAN
	 * address" filter has something to filter */
	put("dev-sipa_eth0", WAN_LINE);

	/* --- the bug this exists for: hotspot up, cable up -> the hotspot address wins --- */
	put("dev-br-wifi", WIFI_LINE);
	put("dev-br-lan", LAN_LINE);
	expect("192.168.8.1", "hotspot and cable both up -> hotspot");

	/* --- hotspot off: br-wifi is gone, so the cable address is what is left --- */
	put("dev-br-wifi", NULL);
	expect("192.168.77.1", "hotspot gone -> cable address");

	/* --- hotspot present but carrying nothing: must not stop the fallback --- */
	put("dev-br-wifi", "");
	expect("192.168.77.1", "hotspot up but addressless -> cable address");

	/* --- neither named interface exists: the full listing, and the address worth printing is
	 * not the one `ip` printed first --- */
	put("dev-br-wifi", NULL);
	put("dev-br-lan", NULL);
	put("all", WAN_LINE LO_LINE USB_LINE WIFI_LINE);
	expect("192.168.77.1", "no named iface -> first usable in the full listing");

	/* --- only the WAN and loopback: nothing to print, so the previous value stays --- */
	put("all", WAN_LINE LO_LINE);
	snprintf(lan_ip, sizeof lan_ip, "192.168.8.1");
	expect("192.168.8.1", "nothing usable -> previous value kept");

	unlink(dir);
	fprintf(stderr, fails ? "FAILURES\n" : "all passed\n");
	return fails != 0;
}
