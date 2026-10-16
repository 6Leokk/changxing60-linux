/* Set wlan0's MAC to this device's factory address, through the vendor's own private ioctl.
 *
 * The driver in use is sprd_wlan_combo, built from changxing60-linux/upstream/modules/sprd_wlan_combo
 * (common/ + sc2355/); the same code also sits in the vendor tree at
 * kernel-src/zte-ums9620-kernel-5.4.254/drivers/unisoc_platform/wlan (marlin3_sipc/ is the other
 * chip variant, not built here), and the references below are by function name because the two
 * copies sit at different line numbers.
 *
 * Why it is needed. The SC2355 reports no MAC of its own -- the firmware's GET_INFO answer carries
 * an invalid address (dmesg has no "mac_addr:" line from sc2355_get_fw_info) -- and nothing in this
 * stack feeds it the one the board actually has. So iface_set_mac_addr() picks
 * random_ether_addr() with a forced 40:45:da OUI and stores *that* as priv->default_mac, which is
 * why the AP's BSSID is different every boot.
 *
 * The board does have a factory MAC: it is in the prodnv partition, which Android mounts at
 * /mnt/vendor -- the very path the driver names in WIFI_MAC_ADDR_PATH. That macro is dead code
 * here (defined, never read); the vendor's own HAL is what applies the file. (A previous session
 * patched iface_set_mac_addr() to also read "androidboot.wifimac=" out of /chosen/bootargs; the
 * module on the device predates that patch and our cmdline carries no such parameter, so neither
 * half of that route is live.)
 *
 * `ip link set wlan0 address ...` is not a way out. iface_set_mac(), the driver's
 * ndo_set_mac_address, handles only the station and P2P cases and otherwise falls straight through
 * to "return success to pass vts test" -- in AP mode it changes nothing and still reports success,
 * which is why a pinned address used to look ignored. The working path is the private ioctl
 * SPRDWLSETNDEVMAC (SIOCDEVPRIVATE + 8), which copies the address into ndev->dev_addr,
 * ndev->perm_addr, wdev.address, priv->default_mac and vif->mac -- everything the BSSID in
 * hostapd's config and in the firmware's START_AP are taken from.
 *
 *   wifimac                 read the address from /mnt/vendor/wifimac.txt
 *   wifimac <aa:bb:..:ff>   use the address given on the command line
 *   wifimac -d <ifname>     a different interface (default wlan0)
 *
 * Run it with the interface down, before hostapd starts. It prints the address the kernel then
 * reports, so the caller can tell a silent no-op from a real change.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>		/* struct ifreq -- the glibc one, so no conflict with linux/if.h */
#include <netinet/in.h>
#include <linux/sockios.h>	/* SIOCDEVPRIVATE */

struct android_wifi_priv_cmd {
	char *buf;
	int used_len;
	int total_len;
};

#define SPRDWLSETNDEVMAC (SIOCDEVPRIVATE + 8)
#define WIFI_MAC_ADDR_PATH "/mnt/vendor/wifimac.txt"

static int parse_mac(const char *s, unsigned char *out)
{
	unsigned int b[6];
	if (sscanf(s, "%x:%x:%x:%x:%x:%x", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6)
		return -1;
	for (int i = 0; i < 6; i++) {
		if (b[i] > 0xff)
			return -1;
		out[i] = (unsigned char)b[i];
	}
	return 0;
}

static const char *read_current(const char *ifname)
{
	static char path[128], buf[32];
	FILE *f;
	snprintf(path, sizeof path, "/sys/class/net/%s/address", ifname);
	f = fopen(path, "r");
	if (!f)
		return "(unknown)";
	if (!fgets(buf, sizeof buf, f)) {
		fclose(f);
		return "(unknown)";
	}
	fclose(f);
	buf[strcspn(buf, "\n")] = 0;
	return buf;
}

int main(int argc, char **argv)
{
	unsigned char mac[6];
	char macs[32] = { 0 };
	const char *ifname = "wlan0";
	int fd, ret;
	struct ifreq ifr;
	struct android_wifi_priv_cmd cmd;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-d") && i + 1 < argc) {
			ifname = argv[++i];
			continue;
		}
		snprintf(macs, sizeof macs, "%s", argv[i]);
	}
	if (!macs[0]) {
		FILE *f = fopen(WIFI_MAC_ADDR_PATH, "r");
		if (!f) {
			fprintf(stderr, "wifimac: %s: %m\n", WIFI_MAC_ADDR_PATH);
			return 1;
		}
		if (!fgets(macs, sizeof macs, f)) {
			fprintf(stderr, "wifimac: %s is empty\n", WIFI_MAC_ADDR_PATH);
			fclose(f);
			return 1;
		}
		fclose(f);
		macs[strcspn(macs, "\r\n")] = 0;
	}
	if (parse_mac(macs, mac)) {
		fprintf(stderr, "wifimac: cannot parse a MAC out of '%s'\n", macs);
		return 1;
	}
	/* the driver rejects these too (main.c:845); say so here rather than print a false success */
	if (mac[0] & 1) {
		fprintf(stderr, "wifimac: %s is a multicast address\n", macs);
		return 1;
	}
	if (!(mac[0] | mac[1] | mac[2] | mac[3] | mac[4] | mac[5])) {
		fprintf(stderr, "wifimac: all-zero address\n");
		return 1;
	}

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		perror("wifimac: socket");
		return 1;
	}

	memset(&ifr, 0, sizeof ifr);
	snprintf(ifr.ifr_name, sizeof ifr.ifr_name, "%s", ifname);
	cmd.buf = (char *)mac;
	cmd.used_len = 0;
	cmd.total_len = sizeof mac;
	ifr.ifr_data = (char *)&cmd;

	ret = ioctl(fd, SPRDWLSETNDEVMAC, &ifr);
	if (ret < 0) {
		perror("wifimac: SPRDWLSETNDEVMAC");
		close(fd);
		return 1;
	}
	close(fd);

	/* the ioctl returns before anything can be read back, and the driver reports success even when
	 * it did nothing, so the sysfs address is the only honest answer */
	printf("%s: %s -> %s\n", ifname, macs, read_current(ifname));
	return 0;
}
