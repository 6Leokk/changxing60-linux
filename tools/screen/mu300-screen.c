/* mu300-screen -- OpenWrt status page on the 7552N's internal 854x480 MIPI panel, plus the
 * power-key backlight toggle.
 *
 * Why it looks like this:
 *  - The kernel has no fbdev (/dev/fb0 does not exist: CONFIG_FB and DRM_FBDEV_EMULATION are both
 *    off), so the only way to paint anything is DRM/KMS on /dev/dri/card0 with a dumb buffer.
 *  - The rootfs has no libdrm and no browser, so this is one static binary: raw DRM ioctls
 *    (drm_min.h), the kernel's own 8x16 console font (font8x16.h), and plain text output.
 *  - The power key is on gpio-keys /dev/input/event0 (KEY_POWER=116). There is no acpid here, so
 *    without this program the key does nothing at all; we bind it to the backlight and nothing else
 *    (a long press must not be turned into a shutdown: the PMIC owns that path).
 *
 * Data sources are read-only and never touch the modem's AT port -- an AT query on a live data call
 * is exactly the failure mode fixed on 2026-10-13 (see rootfs/overlay/opt/mu300/bin/mobile-data).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <signal.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <linux/input.h>
#include "drm_min.h"
#include "font8x16.h"
#include "qr.h"

#define FB_BG      0x00101418u
#define FB_PANEL   0x001c2430u
#define FB_TEXT    0x00e6e6e6u
#define FB_DIM     0x00949aa4u
#define FB_OK      0x0038c172u
#define FB_WARN    0x00e0a020u
#define FB_BAD     0x00e05050u
#define FB_ACCENT  0x0040a0ffu

static volatile sig_atomic_t stop_flag = 0;
static void on_signal(int sig) { (void)sig; stop_flag = 1; }

/* ---------- framebuffer ---------- */
static int drm_fd = -1;
static u32 *fb = NULL;             /* the buffer render() paints into -- never the one on screen */
static u32 *fb_buf[2] = { NULL, NULL };
static u32 fb_id_buf[2] = { 0, 0 };
static u32 crtc_saved = 0;
static int scan_buf = 0;           /* which fb_buf[] the CRTC is scanning out */
static int flip_mode = 1;          /* page flip; cleared for good if the driver refuses one */
static int present_enabled = 1;    /* off for --once/--shot: they read the buffer back, not the panel */
static int fb_w = 0, fb_h = 0, fb_pitch = 0;
static size_t fb_size = 0;         /* one frame, in bytes */
static double px_scale = 1.0;      /* text scale: 854x480 uses 2, larger panels 3 */
/* The label gutter, in characters. 11 fits "Resources" plus a gap on a landscape line; the
 * portrait panel only has 30 columns, so drm_init narrows it to 9 and the values move to their
 * own rows. */
static int LABEL_COLS = 11;

static void fill_rect(int x, int y, int w, int h, u32 color)
{
	if (x < 0) { w += x; x = 0; }
	if (y < 0) { h += y; y = 0; }
	if (x + w > fb_w) w = fb_w - x;
	if (y + h > fb_h) h = fb_h - y;
	for (int j = 0; j < h; j++) {
		u32 *row = fb + (size_t)(y + j) * (fb_pitch / 4) + x;
		for (int i = 0; i < w; i++) row[i] = color;
	}
}

/* 8x16 console font, integer-scaled; returns the x advance */
static int draw_text(int x, int y, int scale, u32 color, const char *s)
{
	for (; *s; s++) {
		unsigned char ch = (unsigned char)*s;
		const unsigned char *g = font8x16 + (ch < 0x20 ? 0 : ch) * 16;
		for (int r = 0; r < 16; r++) {
			unsigned char bits = g[r];
			for (int c = 0; c < 8; c++) {
				if (!(bits & (0x80 >> c))) continue;
				fill_rect(x + c * scale, y + r * scale, scale, scale, color);
			}
		}
		x += 8 * scale;
	}
	return x;
}

static int text_w(int scale, const char *s) { return (int)strlen(s) * 8 * scale; }

/* ---------- small readers ---------- */
static int read_file_str(const char *path, char *buf, size_t n)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0) return -1;
	ssize_t r = read(fd, buf, n - 1);
	close(fd);
	if (r <= 0) return -1;
	buf[r] = 0;
	char *nl = strchr(buf, '\n');
	if (nl) *nl = 0;
	return 0;
}

static long long read_file_ll(const char *path)
{
	char b[64];
	if (read_file_str(path, b, sizeof b) < 0) return -1;
	return atoll(b);
}

/* run a command, capture first line; returns 1 on success */
static int run_cmd(const char *cmd, char *out, size_t n)
{
	FILE *p = popen(cmd, "r");
	if (!p) return 0;
	if (!fgets(out, n, p)) out[0] = 0;
	pclose(p);
	return out[0] != 0;
}

/* ---------- DRM ---------- */
static int drm_open_card(void)
{
	for (int i = 0; i < 8; i++) {
		char path[32];
		snprintf(path, sizeof path, "/dev/dri/card%d", i);
		int fd = open(path, O_RDWR | O_CLOEXEC);
		if (fd >= 0) {
			fprintf(stderr, "mu300-screen: using %s\n", path);
			return fd;
		}
	}
	return -1;
}

static int drm_init(void)
{
	drm_fd = drm_open_card();
	if (drm_fd < 0) { fprintf(stderr, "mu300-screen: no /dev/dri/card*: %s\n", strerror(errno)); return -1; }

	struct drm_mode_card_res res;
	memset(&res, 0, sizeof res);
	if (ioctl(drm_fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
		fprintf(stderr, "mu300-screen: GETRESOURCES: %s\n", strerror(errno));
		return -1;
	}
	u32 connectors[16], crtcs[16], encoders[16];
	int ncon = res.count_connectors < 16 ? res.count_connectors : 16;
	int ncrt = res.count_crtcs < 16 ? res.count_crtcs : 16;
	int nenc = res.count_encoders < 16 ? res.count_encoders : 16;
	memset(&res, 0, sizeof res);
	res.connector_id_ptr = (u64)(uintptr_t)connectors;
	res.crtc_id_ptr = (u64)(uintptr_t)crtcs;
	res.encoder_id_ptr = (u64)(uintptr_t)encoders;
	res.count_connectors = ncon;
	res.count_crtcs = ncrt;
	res.count_encoders = nenc;
	if (ioctl(drm_fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
		fprintf(stderr, "mu300-screen: GETRESOURCES(2): %s\n", strerror(errno));
		return -1;
	}
	if (res.count_crtcs == 0 || res.count_connectors == 0) {
		fprintf(stderr, "mu300-screen: no crtc/connector yet\n");
		return -1;
	}

	u32 con_id = 0, crtc_id = 0;
	struct drm_mode_modeinfo mode;
	memset(&mode, 0, sizeof mode);
	for (u32 i = 0; i < res.count_connectors; i++) {
		struct drm_mode_get_connector c;
		struct drm_mode_modeinfo modes[32];
		/* Probe pass first, with count_modes = 0. drm_mode_getconnector() only calls
		 * connector->fill_modes() -- which is what runs sprd_dsi_connector_detect() and
		 * sets status to CONNECTED -- when the caller asks for zero modes; ask for a
		 * buffer up front and the connector stays at status "unknown" forever and no
		 * mode is ever advertised. This is the same two-pass sequence libdrm uses. */
		memset(&c, 0, sizeof c);
		c.connector_id = connectors[i];
		if (ioctl(drm_fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0) continue;
		if (c.connection != DRM_MODE_CONNECTED) continue;
		memset(&c, 0, sizeof c);
		c.connector_id = connectors[i];
		c.modes_ptr = (u64)(uintptr_t)modes;
		c.count_modes = 32;
		if (ioctl(drm_fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0) continue;
		if (c.connection != DRM_MODE_CONNECTED || c.count_modes == 0) continue;
		if (c.encoder_id) {
			struct drm_mode_get_encoder e;
			memset(&e, 0, sizeof e);
			e.encoder_id = c.encoder_id;
			if (ioctl(drm_fd, DRM_IOCTL_MODE_GETENCODER, &e) == 0 && e.crtc_id) crtc_id = e.crtc_id;
		}
		if (!crtc_id) crtc_id = crtcs[0];
		con_id = c.connector_id;
		mode = modes[0];                       /* the panel driver's preferred mode */
		fprintf(stderr, "mu300-screen: connector %u connected, mode %s %ux%u@%u\n",
			con_id, mode.name, mode.hdisplay, mode.vdisplay, mode.vrefresh);
		break;
	}
	if (!con_id) { fprintf(stderr, "mu300-screen: no connected connector\n"); return -1; }

	fb_w = mode.hdisplay;
	fb_h = mode.vdisplay;
	fb_pitch = fb_w * 4;
	fb_size = (size_t)fb_pitch * fb_h;
	/* Key the font scale off the *short* side. The internal panel is 480x854 portrait, so
	 * looking at fb_w alone picked scale 1 here -- 60x53 characters of 8x16 on a 5" screen,
	 * which is unreadable and leaves two thirds of the panel blank. At scale 2 the font is
	 * 16x32, giving 30 columns by 26 rows, which is what the rows below are laid out for. */
	int short_side = fb_w < fb_h ? fb_w : fb_h;
	px_scale = short_side >= 1200 ? 3 : (short_side >= 400 ? 2 : 1);
	if (fb_h > fb_w + fb_w / 5)
		LABEL_COLS = 10;                /* portrait: 30 columns, so a narrower gutter */

	/* Two dumb buffers. One bound to the CRTC is what the panel scans out, so painting a frame
	 * directly into it is what made the screen flash: render() starts with a full-screen fill and
	 * the rows only come back over the following milliseconds. With two buffers the frame is drawn
	 * off-screen and handed over in one step (page flip, or a copy if the driver refuses one). */
	for (int i = 0; i < 2; i++) {
		struct drm_mode_create_dumb cd;
		memset(&cd, 0, sizeof cd);
		cd.width = fb_w;
		cd.height = fb_h;
		cd.bpp = 32;
		if (ioctl(drm_fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd) < 0) {
			fprintf(stderr, "mu300-screen: CREATE_DUMB: %s\n", strerror(errno));
			return -1;
		}
		fb_pitch = cd.pitch;
		fb_size = (size_t)fb_pitch * fb_h;

		struct drm_mode_fb_cmd fc;
		memset(&fc, 0, sizeof fc);
		fc.width = fb_w;
		fc.height = fb_h;
		fc.pitch = fb_pitch;
		fc.bpp = 32;
		fc.depth = 24;
		fc.handle = cd.handle;
		if (ioctl(drm_fd, DRM_IOCTL_MODE_ADDFB, &fc) < 0) {
			fprintf(stderr, "mu300-screen: ADDFB: %s\n", strerror(errno));
			return -1;
		}
		fb_id_buf[i] = fc.fb_id;

		struct drm_mode_map_dumb md;
		memset(&md, 0, sizeof md);
		md.handle = cd.handle;
		if (ioctl(drm_fd, DRM_IOCTL_MODE_MAP_DUMB, &md) < 0) {
			fprintf(stderr, "mu300-screen: MAP_DUMB: %s\n", strerror(errno));
			return -1;
		}
		void *m = mmap(NULL, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, drm_fd, md.offset);
		if (m == MAP_FAILED) { fprintf(stderr, "mu300-screen: mmap: %s\n", strerror(errno)); return -1; }
		fb_buf[i] = m;
		/* dumb buffer contents are undefined until written; a frame is about to be drawn into
		 * buffer 1, so buffer 0 needs a defined colour for the moment before the first flip */
		for (size_t k = 0; k < fb_size / 4; k++) fb_buf[i][k] = FB_BG;
	}

	struct drm_mode_crtc cr;
	memset(&cr, 0, sizeof cr);
	cr.crtc_id = crtc_id;
	cr.fb_id = fb_id_buf[0];                     /* scan out 0, draw into 1 */
	cr.set_connectors_ptr = (u64)(uintptr_t)&con_id;
	cr.count_connectors = 1;
	cr.mode = mode;
	cr.mode_valid = 1;
	if (ioctl(drm_fd, DRM_IOCTL_MODE_SETCRTC, &cr) < 0) {
		fprintf(stderr, "mu300-screen: SETCRTC: %s\n", strerror(errno));
		return -1;
	}
	crtc_saved = crtc_id;
	scan_buf = 0;
	fb = fb_buf[1];
	fprintf(stderr, "mu300-screen: mode set, %dx%d, pitch %d, scale %g, double buffered\n",
		fb_w, fb_h, fb_pitch, px_scale);
	return 0;
}

/* ---------- presenting a finished frame ----------
 * The invariant everywhere below: fb == fb_buf[scan_buf ^ 1], i.e. the draw target is always the
 * buffer the CRTC is *not* showing.
 *
 * Page flip is the good path: the kernel swaps the scanout to the finished buffer at the next
 * vblank and queues a DRM_EVENT_FLIP_COMPLETE, which is read back on the same fd. A driver that
 * will not take a page flip (or never completes one) drops to a plain copy of the finished frame
 * into the scanned buffer -- one 1.6 MiB memcpy instead of the old draw-into-view, which shrinks
 * the visible partial frame from "the whole repaint" to a single fast blit. */
static int flip_wait(int ms)
{
	fd_set rfds;
	struct timeval tv;
	FD_ZERO(&rfds);
	FD_SET(drm_fd, &rfds);
	tv.tv_sec = ms / 1000;
	tv.tv_usec = (ms % 1000) * 1000;
	if (select(drm_fd + 1, &rfds, NULL, NULL, &tv) <= 0) return -1;

	char buf[256];
	ssize_t n = read(drm_fd, buf, sizeof buf);
	for (ssize_t off = 0; off + (ssize_t)sizeof(struct drm_event) <= n; ) {
		struct drm_event *e = (struct drm_event *)(buf + off);
		if (e->type == DRM_EVENT_FLIP_COMPLETE) return 0;
		if (e->length < sizeof(struct drm_event)) break;
		off += e->length;
	}
	return -1;
}

static void present(void)
{
	if (drm_fd < 0 || !present_enabled) return;
	if (flip_mode) {
		struct drm_mode_crtc_page_flip pf;
		memset(&pf, 0, sizeof pf);
		pf.crtc_id = crtc_saved;
		pf.fb_id = fb_id_buf[scan_buf ^ 1];
		pf.flags = DRM_MODE_PAGE_FLIP_EVENT;
		if (ioctl(drm_fd, DRM_IOCTL_MODE_PAGE_FLIP, &pf) == 0 && flip_wait(500) == 0) {
			scan_buf ^= 1;
			fb = fb_buf[scan_buf ^ 1];
			return;
		}
		flip_mode = 0;
		fprintf(stderr, "mu300-screen: page flip unavailable, switching to buffer copy\n");
	}
	memcpy(fb_buf[scan_buf], fb_buf[scan_buf ^ 1], fb_size);
}

/* ---------- backlight ---------- */
static char bl_brightness[128], bl_max[128];
static int bl_max_val = 255;

static int backlight_find(void)
{
	DIR *d = opendir("/sys/class/backlight");
	if (!d) return -1;
	struct dirent *e;
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.') continue;
		char p[160];
		snprintf(p, sizeof p, "/sys/class/backlight/%.60s/brightness", e->d_name);
		if (access(p, W_OK) != 0) continue;
		snprintf(bl_brightness, sizeof bl_brightness, "%.100s", p);
		snprintf(bl_max, sizeof bl_max, "/sys/class/backlight/%.60s/max_brightness", e->d_name);
		long v = read_file_ll(bl_max);
		if (v > 0) bl_max_val = (int)v;
		closedir(d);
		fprintf(stderr, "mu300-screen: backlight %s (max %d)\n", bl_brightness, bl_max_val);
		return 0;
	}
	closedir(d);
	return -1;
}

static int bl_levels[] = { 0, 25, 50, 75, 100 };   /* percent */
static int bl_index = 4;
static int screen_on = 1;

static void backlight_apply(void)
{
	if (bl_brightness[0] == 0) return;
	int v = bl_max_val * bl_levels[bl_index] / 100;
	FILE *f = fopen(bl_brightness, "w");
	if (!f) return;
	fprintf(f, "%d\n", v);
	fclose(f);
	screen_on = bl_index > 0 || bl_levels[bl_index] > 0;
	if (bl_index == 0) screen_on = 0;
	else screen_on = 1;
	fprintf(stderr, "mu300-screen: backlight %d%% (%d)\n", bl_levels[bl_index], v);
}

/* ---------- status data ---------- */
struct wifi_sta { char mac[18]; int signal; };
struct wifi_sta sta[16];
static int sta_n = 0;
static char ssid[64] = "?", psk[64] = "-", wifi_addr[18] = "-", wifi_ch[16] = "-";
static int wifi_clients = 0;
static char wan_if[24] = "sipa_eth0", wan_ip[40] = "-", wan_mask[8] = "-", wan_state[12] = "-";
static unsigned long long wan_rx = 0, wan_tx = 0, wlan_rx = 0, wlan_tx = 0;
static char lan_ip[40] = "192.168.77.1";
static long long sys_uptime = 0;
static int mem_total_kb = 0, mem_avail_kb = 0, zram_kb = 0;
static int temp_max = 0, batt_cap = -1, batt_volt = 0;
static char batt_status[24] = "-";
static int tz = 1;   /* refresh cadence counter */

static void human_bytes(unsigned long long b, char *out, size_t n)
{
	double v = (double)b;
	if (v >= 1024.0 * 1024 * 1024) snprintf(out, n, "%.2f GiB", v / (1024.0 * 1024 * 1024));
	else if (v >= 1024.0 * 1024) snprintf(out, n, "%.1f MiB", v / (1024.0 * 1024));
	else if (v >= 1024.0) snprintf(out, n, "%.0f KiB", v / 1024.0);
	else snprintf(out, n, "%.0f B", v);
}

/* Same magnitudes, no space before a single-letter unit. The rx/tx row shares one line with two
 * values: the portrait panel gives that row 19 columns and "rx 145 KiB  tx 53 KiB" is 21, so the
 * readable form gets its tail clipped ("tx 53 K"). "rx 145K  tx 53K" is 15. */
static void human_bytes_short(unsigned long long b, char *out, size_t n)
{
	double v = (double)b;
	if (v >= 1024.0 * 1024 * 1024) snprintf(out, n, "%.2fG", v / (1024.0 * 1024 * 1024));
	else if (v >= 1024.0 * 1024) snprintf(out, n, "%.1fM", v / (1024.0 * 1024));
	else if (v >= 1024.0) snprintf(out, n, "%.0fK", v / 1024.0);
	else snprintf(out, n, "%.0fB", v);
}

static void read_cmdline_wan(void)
{
	/* The modem netdev is sipa_eth<cid-1>, and opt/mu300/bin/mobile-data pins CID=1, so the data
	 * channel is sipa_eth0. The trap: /sys/class/net carries all sixteen sipa_eth* netdevs and
	 * readdir() hands them back in filesystem order, not numeric order -- taking the first match
	 * reported "sipa_eth8 down" while sipa_eth0 was up and passing traffic.
	 *
	 * So pick by liveness instead: mobile-data takes the link down when the call drops, so the one
	 * interface that is up is the one carrying it. Fall back to sipa_eth0 when nothing is up, which
	 * keeps the page naming the right device (state "down", not "absent") while the call is away. */
	char live[24] = "";
	DIR *d = opendir("/sys/class/net");
	if (d) {
		struct dirent *e;
		while ((e = readdir(d))) {
			char p[64], b[32];
			if (strncmp(e->d_name, "sipa_eth", 8) != 0) continue;
			snprintf(p, sizeof p, "/sys/class/net/%.15s/operstate", e->d_name);
			if (read_file_str(p, b, sizeof b) != 0 || strncmp(b, "up", 2) != 0) continue;
			snprintf(live, sizeof live, "%.15s", e->d_name);   /* sipa_eth0 = cid 1 wins */
			if (strcmp(e->d_name, "sipa_eth0") == 0) break;
		}
		closedir(d);
	}
	snprintf(wan_if, sizeof wan_if, "%s", live[0] ? live : "sipa_eth0");
}

static void read_wifi_config(void)
{
	/* the AP config is generated by opt/mu300/bin/openwrt-wifi-config into /etc/config/wireless */
	FILE *f = fopen("/etc/config/wireless", "r");
	if (f) {
		char line[256];
		while (fgets(line, sizeof line, f)) {
			char *p;
			if ((p = strstr(line, "option ssid"))) { sscanf(p + 11, " '%63[^']'", ssid); }
			else if ((p = strstr(line, "option key"))) { sscanf(p + 10, " '%63[^']'", psk); }
			else if ((p = strstr(line, "option channel"))) { sscanf(p + 15, " '%15[^']'", wifi_ch); }
		}
		fclose(f);
	}
	char b[32];
	if (read_file_str("/sys/class/net/wlan0/address", b, sizeof b) == 0)
		snprintf(wifi_addr, sizeof wifi_addr, "%.17s", b);
}

static void read_counters(void)
{
	FILE *f = fopen("/proc/net/dev", "r");
	if (!f) return;
	char line[256];
	while (fgets(line, sizeof line, f)) {
		char *colon = strchr(line, ':');
		if (!colon) continue;
		char name[32];
		int nl = (int)(colon - line);
		if (nl >= (int)sizeof name) continue;
		memcpy(name, line, nl);
		name[nl] = 0;
		char *nm = name;
		while (*nm == ' ') nm++;
		unsigned long long rx, tx;
		if (sscanf(colon + 1, " %llu %*u %*u %*u %*u %*u %*u %*u %llu", &rx, &tx) != 2) continue;
		if (strcmp(nm, wan_if) == 0) { wan_rx = rx; wan_tx = tx; }
		else if (strcmp(nm, "wlan0") == 0) { wlan_rx = rx; wlan_tx = tx; }
	}
	fclose(f);
}

static void read_system(void)
{
	char b[512];
	sys_uptime = read_file_ll("/proc/uptime");
	FILE *f = fopen("/proc/meminfo", "r");
	mem_total_kb = mem_avail_kb = 0;
	if (f) {
		while (fgets(b, sizeof b, f)) {
			if (!strncmp(b, "MemTotal:", 9)) mem_total_kb = atoi(b + 9);
			else if (!strncmp(b, "MemAvailable:", 13)) mem_avail_kb = atoi(b + 13);
			else if (!strncmp(b, "SwapTotal:", 10)) zram_kb = atoi(b + 10);
		}
		fclose(f);
	}
	DIR *d = opendir("/sys/class/thermal");
	temp_max = 0;
	if (d) {
		struct dirent *e;
		while ((e = readdir(d))) {
			if (strncmp(e->d_name, "thermal_zone", 12) != 0) continue;
			char p[160];
			snprintf(p, sizeof p, "/sys/class/thermal/%.60s/temp", e->d_name);
			long long t = read_file_ll(p);
			if (t > 0 && t < 200000 && (int)t > temp_max) temp_max = (int)t;
		}
		closedir(d);
	}
	/* Three nodes carry battery data and only two of them matter:
	 *   battery/capacity        92    charger-manager, already percent
	 *   sc27xx-fgu/capacity     885   the real fuel gauge, in per-mille (88.5%)
	 *   bq2560x_charger/status  Full  input side only, no capacity
	 * The old `c >= 0 && c <= 100` test threw the gauge away, so the page depended entirely on the
	 * charger-manager node; whenever that one was not ready the row fell through to "no fuel gauge"
	 * on a device whose fuel gauge was answering fine. Accept both scales. No early break: one node
	 * may know the capacity and another the status. */
	const char *ps[] = { "battery", "sc27xx-fgu", "bq2560x_charger" };
	batt_cap = -1; batt_status[0] = '-'; batt_status[1] = 0; batt_volt = 0;
	for (unsigned i = 0; i < sizeof ps / sizeof ps[0]; i++) {
		char p[160];
		snprintf(p, sizeof p, "/sys/class/power_supply/%.30s/capacity", ps[i]);
		long long c = read_file_ll(p);
		if (c > 100 && c <= 1000) c = (c + 5) / 10;          /* per-mille gauge -> percent */
		if (c >= 0 && c <= 100 && batt_cap < 0) batt_cap = (int)c;
		snprintf(p, sizeof p, "/sys/class/power_supply/%.30s/status", ps[i]);
		if (read_file_str(p, b, sizeof b) == 0 &&
		    (strcmp(b, "Charging") == 0 || strcmp(b, "Discharging") == 0 ||
		     strcmp(b, "Full") == 0 || strcmp(b, "Not charging") == 0) &&
		    (batt_status[0] == '-' || strcmp(batt_status, "Unknown") == 0))
			snprintf(batt_status, sizeof batt_status, "%.15s", b);
		snprintf(p, sizeof p, "/sys/class/power_supply/%.30s/voltage_now", ps[i]);
		long long v = read_file_ll(p);
		if (v > 0 && batt_volt == 0) batt_volt = (int)(v / 1000);
	}
	if (batt_status[0] == '-') snprintf(batt_status, sizeof batt_status, "Unknown");
}

static void read_wan(void)
{
	char b[512], p[200];
	snprintf(p, sizeof p, "/sys/class/net/%.15s/operstate", wan_if);
	if (read_file_str(p, b, sizeof b) == 0) snprintf(wan_state, sizeof wan_state, "%.11s", b);
	else snprintf(wan_state, sizeof wan_state, "absent");
	/* operstate is not enough to call the WAN healthy: a wedged data call keeps it "up" forever
	 * (2026-10-13: green "sipa_eth0 up" for the whole boot while the interface carried no packets
	 * and every client behind it had no internet). The watchdog's measured verdict wins when it is
	 * fresh -- stale verdicts from an earlier boot must not stick to a call that now works. */
	if (read_file_str("/tmp/mu300-wan-health", b, sizeof b) == 0) {
		char verdict[8] = "";
		long long at = 0;
		if (sscanf(b, "%7s %lld", verdict, &at) == 2 && strcmp(verdict, "dead") == 0) {
			long long up = read_file_ll("/proc/uptime");
			if (up > 0 && at > 0 && up - at < 900)
				snprintf(wan_state, sizeof wan_state, "no net");
		}
	}
	wan_ip[0] = '-'; wan_ip[1] = 0;
	snprintf(p, sizeof p, "ip -4 -o addr show dev %s 2>/dev/null", wan_if);
	if (run_cmd(p, b, sizeof b)) {
		char *inet = strstr(b, "inet ");
		if (inet) {
			char cidr[40];
			if (sscanf(inet + 5, "%39s", cidr) == 1) {
				char *slash = strchr(cidr, '/');
				if (slash) { snprintf(wan_mask, sizeof wan_mask, "%.4s", slash + 1); *slash = 0; }
				snprintf(wan_ip, sizeof wan_ip, "%.39s", cidr);
			}
		}
	}
	/* LAN address: first global IPv4 that is not the WAN one */
	if (run_cmd("ip -4 -o addr show 2>/dev/null", b, sizeof b)) {
		char cidr[40];
		char *q = b;
		while ((q = strstr(q, "inet "))) {
			q += 5;
			if (sscanf(q, "%39s", cidr) == 1) {
				char *slash = strchr(cidr, '/');
				if (slash) *slash = 0;
				if (strcmp(cidr, wan_ip) != 0 && strncmp(cidr, "127.", 4) != 0) {
					snprintf(lan_ip, sizeof lan_ip, "%.39s", cidr);
					break;
				}
			}
		}
	}
}

static void read_wifi(void)
{
	char b[2048];
	wifi_clients = 0;
	sta_n = 0;
	if (run_cmd("iw dev wlan0 station dump 2>/dev/null", b, sizeof b)) {
		char *q = b;
		while ((q = strstr(q, "Station "))) {
			wifi_clients++;
			if (sta_n < 16) {
				struct wifi_sta *s = &sta[sta_n++];
				snprintf(s->mac, sizeof s->mac, "%.17s", q + 8);
				s->signal = 0;
				char *sig = strstr(q, "signal:");
				if (sig) s->signal = atoi(sig + 7);
			}
			q += 8;
		}
	}
	if (run_cmd("iw dev wlan0 info 2>/dev/null | sed -n 's/.*channel \\([0-9]*\\).*/\\1/p'", b, sizeof b))
		snprintf(wifi_ch, sizeof wifi_ch, "%.15s", b);
}

/* ---------- page ---------- */

/* One label/value row. `limit` is the right-hand edge of the text column: everything right of it
 * belongs to the QR, so the value is clipped rather than allowed to run under it. */
static void status_line(int y, const char *label, const char *value, u32 vcolor, int limit)
{
	int sc = (int)px_scale;
	int x0 = 8 + LABEL_COLS * 8 * sc;
	int cols = (limit - x0) / (8 * sc);
	char v[96];
	if (cols > (int)sizeof v - 1) cols = (int)sizeof v - 1;
	if (cols < 0) cols = 0;
	snprintf(v, sizeof v, "%.*s", cols, value);
	draw_text(8, y, sc, FB_DIM, label);
	draw_text(x0, y, sc, vcolor, v);
}

/* Quiet zone of 2 modules, then the symbol, alternating colours so the grid stays readable. */
static void draw_qr(int x0, int y0, int scale, const char *text)
{
	unsigned char m[41 * 41];
	int n = qr_encode(text, m);
	if (n < 0) {
		draw_text(x0, y0 + 40 * scale / 2, scale, FB_WARN, "qr: url too long");
		return;
	}
	int q = 2 * scale;
	fill_rect(x0, y0, n * scale + 2 * q, n * scale + 2 * q, 0x00ffffffu);
	for (int y = 0; y < n; y++)
		for (int x = 0; x < n; x++)
			if (m[y * n + x])
				fill_rect(x0 + q + x * scale, y0 + q + y * scale, scale, scale, 0x00000000u);
}

/* ---------- battery ----------
 * The page is this device's only battery indicator, so the row has to survive a fuel gauge that
 * answers on a different scale: sc27xx-fgu reports per-mille (885 = 88.5%) while the
 * charger-manager node reports percent. read_system() normalises both; these two keep the row from
 * ever rendering as a bare "no fuel gauge" when a real number is available. */
static void battery_line(char *out, size_t n)
{
	const char *st = batt_status;
	if (strcmp(st, "Charging") == 0) st = "CHG";
	else if (strcmp(st, "Discharging") == 0) st = "DIS";
	else if (strcmp(st, "Full") == 0) st = "FULL";
	else if (strcmp(st, "Not charging") == 0) st = "IDLE";
	if (batt_cap < 0)
		snprintf(out, n, batt_volt > 0 ? "%d.%02dV" : "unavailable",
			 batt_volt / 1000, (batt_volt % 1000) / 10);
	else if (batt_volt > 0)
		snprintf(out, n, "%d%%  %s  %d.%02dV", batt_cap, st, batt_volt / 1000, (batt_volt % 1000) / 10);
	else
		snprintf(out, n, "%d%%  %s", batt_cap, st);
}

/* A level bar beside the text, so the row reads as a battery and not as another log line. Skipped
 * when the (possibly truncated) value already reaches where the bar would go. */
static void draw_batt_bar(int y, int sc, int limit, int pct, const char *text)
{
	int x0 = 8 + LABEL_COLS * 8 * sc;
	int cols = (limit - x0) / (8 * sc);
	int vlen = (int)strlen(text);
	if (cols >= 0 && vlen > cols) vlen = cols;
	int w = 14 * sc, h = 9 * sc;
	int x = limit - w - 2 * sc;
	if (cols < 0 || x < x0 + vlen * 8 * sc + 4 * sc) return;
	u32 col = pct < 0 ? FB_DIM : (pct <= 15 ? FB_BAD : (pct <= 30 ? FB_WARN : FB_OK));
	fill_rect(x, y + 6 * sc, w, h, FB_DIM);                     /* shell */
	fill_rect(x + 2, y + 6 * sc + 2, w - 4, h - 4, FB_BG);
	if (pct > 0) fill_rect(x + 2, y + 6 * sc + 2, (w - 4) * pct / 100, h - 4, col);
	fill_rect(x + w, y + 6 * sc + h / 3, 3, h / 3, FB_DIM);     /* terminal nub */
}

static void render(void)
{
	fill_rect(0, 0, fb_w, fb_h, FB_BG);
	int sc = (int)px_scale;
	int row_h = 16 * sc + 4 * sc;
	char line[256], url[64];

	/* The internal panel is 480x854 portrait: 30 columns by 26 rows at scale 2. A label and a
	 * full value do not fit on one 30-column line the way they do in landscape, so in portrait
	 * every value moves to its own row under the narrower gutter and the groups are separated
	 * by a gap. The page needs 11 rows and has 19, so the spare becomes breathing room. */
	int portrait = fb_h > fb_w + fb_w / 5;
	int gap = portrait ? 10 : 0;

	/* --- header --- */
	fill_rect(0, 0, fb_w, 20 * sc, FB_PANEL);
	draw_text(8, 4 * sc, sc, FB_ACCENT, portrait ? "MU300" : "MU300 / changxing60");
	snprintf(line, sizeof line, "OpenWrt 25.12.5");
	draw_text(fb_w - 8 - text_w(sc, line), 4 * sc, sc, FB_DIM, line);

	/* --- QR of the LuCI URL, and the key-hint row ---
	 * Portrait: the code is centred on its own row above the footer, so the text rows above
	 * get the full width. Landscape: it takes the bottom-right corner and the rows stop short
	 * of its column. */
	snprintf(url, sizeof url, "http://%s/", lan_ip);
	int qr_scale = portrait ? 6 : (fb_w >= 1200 ? 6 : 5);
	int qr_n = 25;                                   /* version 2 covers a 20-char URL */
	int qr_px = qr_n * qr_scale + 4 * qr_scale;
	/* The glyph cell is 16 rows tall (the font is 8x16), so the hint row needs 16*sc, not 8*sc: at
	 * fb_h - 26*sc its lower 12 px reached into the 40-px footer bar and printed through the URL
	 * line ("power=on/off vol=dim" and "LuCI http://..." were unreadable on top of each other). Keep
	 * the whole cell above the bar with a 2*sc gap. */
	int hint_y = portrait ? fb_h - 38 * sc : fb_h - 16 * sc;
	int qr_x = portrait ? (fb_w - qr_px) / 2 : fb_w - 8 - qr_px;
	int qr_y = portrait ? hint_y - 12 * sc - qr_px : fb_h - 20 * sc - 8 - qr_px;
	draw_qr(qr_x, qr_y, qr_scale, url);
	int limit = portrait ? fb_w - 8 : qr_x - 16;

	/* --- rows --- */
	int y = 26 * sc;
	char rx[32], tx[32];
	if (portrait) {
		human_bytes_short(wan_rx, rx, sizeof rx);
		human_bytes_short(wan_tx, tx, sizeof tx);
	} else {
		human_bytes(wan_rx, rx, sizeof rx);
		human_bytes(wan_tx, tx, sizeof tx);
	}

	u32 wan_ok = (strcmp(wan_state, "up") == 0 || strcmp(wan_state, "unknown") == 0) ? FB_OK : FB_BAD;

	char load[64] = "-";
	FILE *f = fopen("/proc/loadavg", "r");
	if (f) {
		/* only the 1-minute average: the 5- and 15-minute figures are noise at this size */
		char buf[128];
		if (fgets(buf, sizeof buf, f) && sscanf(buf, "%15s", load) != 1)
			snprintf(load, sizeof load, "-");
		fclose(f);
	}

	if (portrait) {
		snprintf(line, sizeof line, "%s %s", wan_if, wan_state);
		status_line(y, "WAN", line, wan_ok, limit);
		y += row_h;
		snprintf(line, sizeof line, "%s/%s", wan_ip, wan_mask);
		status_line(y, "", line, FB_TEXT, limit);
		y += row_h;
		snprintf(line, sizeof line, "rx %s  tx %s", rx, tx);
		status_line(y, "", line, FB_DIM, limit);
		y += row_h + gap;

		snprintf(line, sizeof line, "%s ch%s", ssid, wifi_ch);
		status_line(y, "WiFi AP", line, wifi_clients > 0 ? FB_OK : FB_WARN, limit);
		y += row_h;
		/* the passphrase itself is deliberately not printed: LuCI shows it, and it does not
		 * belong on a screen anyone standing nearby can read */
		snprintf(line, sizeof line, "%s", wifi_addr);
		status_line(y, "", line, FB_TEXT, limit);
		y += row_h;
		if (sta_n > 0)
			snprintf(line, sizeof line, "%d client%s  %d dBm", wifi_clients,
				 wifi_clients == 1 ? "" : "s", sta[0].signal);
		else
			snprintf(line, sizeof line, "no clients");
		status_line(y, "", line, sta_n > 0 ? FB_TEXT : FB_DIM, limit);
		y += row_h + gap;

		snprintf(line, sizeof line, "load %s", load);
		status_line(y, "System", line, temp_max > 80000 ? FB_BAD : FB_TEXT, limit);
		y += row_h;
		snprintf(line, sizeof line, "up %lldh%02lldm  %d.%dC", sys_uptime / 3600,
			 (sys_uptime / 60) % 60, temp_max / 1000, (temp_max % 1000) / 100);
		status_line(y, "", line, temp_max > 80000 ? FB_BAD : FB_DIM, limit);
		y += row_h + gap;

		snprintf(line, sizeof line, "ram %d/%d MB", (mem_total_kb - mem_avail_kb) / 1024,
			 mem_total_kb / 1024);
		status_line(y, "Resources", line, FB_TEXT, limit);
		y += row_h;
		snprintf(line, sizeof line, "swap %d MB", zram_kb / 1024);
		status_line(y, "", line, FB_DIM, limit);
		y += row_h + gap;

		battery_line(line, sizeof line);
		u32 bcol = batt_cap < 0 ? FB_DIM : (batt_cap <= 15 ? FB_BAD : (batt_cap <= 30 ? FB_WARN : FB_OK));
		status_line(y, "Battery", line, bcol, limit);
		draw_batt_bar(y, sc, limit, batt_cap, line);
	} else {
		snprintf(line, sizeof line, "%s %s  %s/%s", wan_if, wan_state, wan_ip, wan_mask);
		status_line(y, "WAN", line, wan_ok, limit);
		y += row_h;
		snprintf(line, sizeof line, "rx %s  tx %s", rx, tx);
		status_line(y, "", line, FB_DIM, limit);
		y += row_h;

		snprintf(line, sizeof line, "%s  ch%s  %d client%s", ssid, wifi_ch, wifi_clients,
			 wifi_clients == 1 ? "" : "s");
		status_line(y, "WiFi AP", line, wifi_clients > 0 ? FB_OK : FB_WARN, limit);
		y += row_h;
		snprintf(line, sizeof line, "%s  wpa2%s", wifi_addr,
			 psk[0] && strcmp(psk, "-") ? " psk" : " open");
		status_line(y, "", line, FB_DIM, limit);
		y += row_h;
		for (int i = 0; i < sta_n && i < 2; i++) {
			snprintf(line, sizeof line, "%.17s  %d dBm", sta[i].mac, sta[i].signal);
			status_line(y, i == 0 ? "clients" : "", line, FB_TEXT, limit);
			y += row_h;
		}

		snprintf(line, sizeof line, "load %s  up %lldh%02lldm  %d.%dC", load, sys_uptime / 3600,
			 (sys_uptime / 60) % 60, temp_max / 1000, (temp_max % 1000) / 100);
		status_line(y, "System", line, temp_max > 80000 ? FB_BAD : FB_TEXT, limit);
		y += row_h;

		snprintf(line, sizeof line, "ram %d/%d MB  swap %d MB",
			 (mem_total_kb - mem_avail_kb) / 1024, mem_total_kb / 1024, zram_kb / 1024);
		status_line(y, "Resources", line, FB_TEXT, limit);
		y += row_h;

		battery_line(line, sizeof line);
		u32 bcol = batt_cap < 0 ? FB_DIM : (batt_cap <= 15 ? FB_BAD : (batt_cap <= 30 ? FB_WARN : FB_OK));
		status_line(y, "Battery", line, bcol, limit);
		draw_batt_bar(y, sc, limit, batt_cap, line);
	}

	/* --- footer: URL left, key hints right ---
	 * On the portrait panel they cannot share one 30-column line (25 + 21 characters), so the
	 * hints sit on their own dim row above the bar; in landscape they fit on the bar itself. */
	fill_rect(0, fb_h - 20 * sc, fb_w, 20 * sc, FB_PANEL);
	snprintf(line, sizeof line, "LuCI %s", url);
	draw_text(8, fb_h - 16 * sc, sc, FB_TEXT, line);
	snprintf(line, sizeof line, "power=on/off vol=dim");
	draw_text(fb_w - 8 - text_w(sc, line), hint_y, sc, FB_DIM, line);

	/* The frame is complete in the off-screen buffer; hand it to the panel in one step. No-op
	 * for --dump (no DRM) and for --shot (the caller reads the buffer back right after). */
	present();
}

/* ---------- input ---------- */
/* Every event device, not just event0. The panel keys are on gpio-keys, which is event0 today,
 * but nothing guarantees that ordering across boots or once the touch controller is enabled --
 * and a power key that quietly stops working because the device moved is the worst failure mode
 * this program has. Opening them all costs nothing: non-key events are ignored.
 *
 * Devices are re-scanned on the refresh tick rather than opened once at startup, because a device
 * that appears a moment after we start would otherwise be missed forever. That is not hypothetical:
 * it is exactly what happens to the synthetic key injector (keyinject), whose uinput device only
 * exists once it has been started. */
#define MAX_IN 8
static int in_fd[MAX_IN];
static int in_n = 0;
static unsigned in_mask = 0;             /* bit i set = /dev/input/event<i> is open */

/* Opens every event device not open yet; returns how many were added. */
static int input_scan(void)
{
	char p[40];
	int added = 0;
	for (int i = 0; i < MAX_IN && in_n < MAX_IN; i++) {
		if (in_mask & (1u << i)) continue;
		snprintf(p, sizeof p, "/dev/input/event%d", i);
		int fd = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0) continue;
		in_fd[in_n++] = fd;
		in_mask |= 1u << i;
		added++;
	}
	return added;
}

static void handle_key(__u16 code, __s32 value)
{
	if (value != 1) return;                 /* press only: ignore release and autorepeat */
	if (code == KEY_POWER) {
		if (screen_on) { bl_index = 0; }
		else { bl_index = (bl_index <= 0 || bl_index > 4) ? 4 : bl_index; }
		backlight_apply();
	} else if (code == KEY_VOLUMEUP) {
		if (bl_index < 4) bl_index++;
		backlight_apply();
	} else if (code == KEY_VOLUMEDOWN) {
		if (bl_index > 0) bl_index--;
		backlight_apply();
	}
}

/* ---------- offline frame dump (--dump FILE, used to check the layout without a panel) ---------- */
static void mock_data(void)
{
	snprintf(ssid, sizeof ssid, "MU300-D0FD");
	snprintf(psk, sizeof psk, "example-not-a-real-key");   /* nothing here is real: --dump is a preview */
	snprintf(wifi_addr, sizeof wifi_addr, "40:45:da:12:d0:fd");
	snprintf(wifi_ch, sizeof wifi_ch, "6");
	snprintf(wan_if, sizeof wan_if, "sipa_eth0");
	snprintf(wan_ip, sizeof wan_ip, "10.44.128.77");
	snprintf(wan_mask, sizeof wan_mask, "30");
	snprintf(wan_state, sizeof wan_state, "up");
	snprintf(lan_ip, sizeof lan_ip, "192.168.77.1");
	wan_rx = 128ull * 1024 * 1024;
	wan_tx = 9ull * 1024 * 1024;
	sys_uptime = 3 * 3600 + 41 * 60;
	mem_total_kb = 5 * 1024 * 1024 + 512 * 1024;
	mem_avail_kb = 4 * 1024 * 1024 + 100 * 1024;
	zram_kb = 2 * 1024 * 1024;
	temp_max = 42300;
	batt_cap = 87;
	batt_volt = 4102;
	snprintf(batt_status, sizeof batt_status, "Discharging");
	wifi_clients = 2;
	sta_n = 2;
	snprintf(sta[0].mac, sizeof sta[0].mac, "a4:5e:60:11:22:33");
	sta[0].signal = -47;
	snprintf(sta[1].mac, sizeof sta[1].mac, "8c:53:c3:aa:bb:cc");
	sta[1].signal = -68;
}

static int dump_ppm(const char *path)
{
	FILE *f = fopen(path, "wb");
	if (!f) { fprintf(stderr, "mu300-screen: %s: %s\n", path, strerror(errno)); return -1; }
	fprintf(f, "P6\n%d %d\n255\n", fb_w, fb_h);
	for (int y = 0; y < fb_h; y++)
		for (int x = 0; x < fb_w; x++) {
			u32 p = fb[(size_t)y * (fb_pitch / 4) + x];
			unsigned char rgb[3] = { (unsigned char)(p >> 16), (unsigned char)(p >> 8), (unsigned char)p };
			fwrite(rgb, 1, 3, f);
		}
	fclose(f);
	fprintf(stderr, "mu300-screen: wrote %s (%dx%d)\n", path, fb_w, fb_h);
	return 0;
}

int main(int argc, char **argv)
{
	int once = (argc > 1 && strcmp(argv[1], "--once") == 0);
	/* --shot FILE: one modeset + one render, then write the scanout buffer out as a PPM. Same
	 * path as --once but it hands back what the panel is actually being fed, so the layout can
	 * be checked from the host (over ssh) instead of by looking at the device. */
	const char *shot = (argc > 2 && strcmp(argv[1], "--shot") == 0) ? argv[2] : NULL;
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGPIPE, SIG_IGN);

	if (argc > 2 && strcmp(argv[1], "--dump") == 0) {
		/* No DRM, no panel: build a frame in ordinary memory from a representative sample of
		 * data so the layout can be eyeballed (and checked in CI) on any machine.
		 * `--dump FILE portrait` selects the panel's own orientation: the two branches below lay
		 * out differently, and the wrong one is otherwise only ever seen on the real device. */
		int want_portrait = (argc > 3 && strcmp(argv[3], "portrait") == 0);
		fb_w = want_portrait ? 480 : 854;
		fb_h = want_portrait ? 854 : 480;
		fb_pitch = fb_w * 4;
		fb_size = (size_t)fb_pitch * fb_h;
		px_scale = 2;
		if (fb_h > fb_w + fb_w / 5) LABEL_COLS = 10;   /* same rule as drm_init */
		fb = calloc(1, fb_size);
		if (!fb) return 1;
		mock_data();
		render();
		return dump_ppm(argv[2]) == 0 ? 0 : 1;
	}

	if (once || shot) present_enabled = 0;   /* both dump the drawn buffer, not the panel */

	if (drm_init() < 0) return 1;
	if (backlight_find() == 0) backlight_apply();

	if (input_scan() == 0)
		fprintf(stderr, "mu300-screen: no /dev/input/event*: %s (keys disabled)\n",
			strerror(errno));
	else
		fprintf(stderr, "mu300-screen: %d input device(s)\n", in_n);

	read_cmdline_wan();
	read_wifi_config();
	read_system();
	read_wan();
	read_wifi();
	read_counters();
	(void)!write(1, "\n", 1);  /* flush line-buffered logs when attached to a terminal */
	render();
	if (shot) return dump_ppm(shot) == 0 ? 0 : 1;
	if (once) return 0;

	struct timeval tv_last = { 0, 0 };
	while (!stop_flag) {
		fd_set rfds;
		struct timeval tv = { 2, 0 };
		FD_ZERO(&rfds);
		int maxfd = -1;
		for (int i = 0; i < in_n; i++) {
			FD_SET(in_fd[i], &rfds);
			if (in_fd[i] > maxfd) maxfd = in_fd[i];
		}
		int r = select(maxfd + 1, &rfds, NULL, NULL, &tv);
		if (r < 0 && errno != EINTR) break;
		for (int i = 0; r > 0 && i < in_n; i++) {
			if (!FD_ISSET(in_fd[i], &rfds)) continue;
			struct input_event ev;
			while (read(in_fd[i], &ev, sizeof ev) == (ssize_t)sizeof ev) {
				if (ev.type == EV_KEY) {
					struct timeval now;
					gettimeofday(&now, NULL);
					long ms = (now.tv_sec - tv_last.tv_sec) * 1000 + (now.tv_usec - tv_last.tv_usec) / 1000;
					if (ms >= 150) { tv_last = now; handle_key(ev.code, ev.value); }
				}
			}
		}
		/* cheap, and it keeps the key path alive across renumbering: a device that appeared
		 * after startup is picked up here rather than being missed until the next restart */
		if (input_scan())
			fprintf(stderr, "mu300-screen: %d input device(s)\n", in_n);
		if (!screen_on) continue;                       /* nothing to repaint while dark */
		tz++;
		read_system();
		read_wan();
		read_counters();
		if (tz % 2 == 0) read_wifi();                   /* iw is the expensive one */
		render();
	}
	fprintf(stderr, "mu300-screen: exiting\n");
	return 0;
}
