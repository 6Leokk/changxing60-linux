/* Minimal QR encoder -- byte mode, error-correction level L, versions 1..5.
 *
 * Scope is deliberately narrow: we only ever encode one short URL ("http://<lan-ip>/", ~20 bytes),
 * and at level L versions 1-5 are each a *single* Reed-Solomon block, which removes the whole
 * interleaving stage. Anything longer than 106 bytes fails loudly instead of emitting a bad symbol.
 *
 * Tables (level L, single block):
 *   ver  size  data codewords  ecc codewords  byte-mode capacity
 *    1    21        19              7              17
 *    2    25        34             10              32
 *    3    29        55             15              53
 *    4    33        80             20              78
 *    5    37       108             26             106
 */
#include "qr.h"
#include <string.h>

#define MAX_SIZE 37
#define MAX_CODE 134

static const struct { int size, data, ecc, cap; } VER[] = {
	{ 21,  19,  7,  17 },
	{ 25,  34, 10,  32 },
	{ 29,  55, 15,  53 },
	{ 33,  80, 20,  78 },
	{ 37, 108, 26, 106 },
};
#define NVER ((int)(sizeof VER / sizeof VER[0]))

/* ---------- GF(256) ---------- */
static unsigned char gf_exp[512], gf_log[256];
static int gf_ready = 0;

static void gf_init(void)
{
	int x = 1;
	memset(gf_log, 0, sizeof gf_log);
	for (int i = 0; i < 255; i++) {
		gf_exp[i] = (unsigned char)x;
		gf_log[x] = (unsigned char)i;
		x <<= 1;
		if (x & 0x100) x ^= 0x11d;
	}
	for (int i = 255; i < 512; i++) gf_exp[i] = gf_exp[i - 255];
	gf_ready = 1;
}

static unsigned char gf_mul(unsigned char a, unsigned char b)
{
	if (!a || !b) return 0;
	return gf_exp[gf_log[a] + gf_log[b]];
}

/* data[0..ndata-1] -> out[0..nec-1] */
static void rs_ecc(const unsigned char *data, int ndata, int nec, unsigned char *out)
{
	unsigned char g[32], rem[32];
	/* g is stored leading-coefficient-first; multiply by (x + a^i) each round. The leading
	 * coefficient must stay 1 (monic), so g[0] is deliberately never touched. */
	memset(g, 0, sizeof g);
	g[0] = 1;
	for (int i = 0; i < nec; i++)
		for (int j = i + 1; j > 0; j--)
			g[j] = g[j] ^ gf_mul(g[j - 1], gf_exp[i]);
	memset(rem, 0, nec);
	for (int i = 0; i < ndata; i++) {
		unsigned char factor = data[i] ^ rem[0];
		memmove(rem, rem + 1, nec - 1);
		rem[nec - 1] = 0;
		for (int j = 0; j < nec; j++)
			rem[j] ^= gf_mul(g[j + 1], factor);
	}
	memcpy(out, rem, nec);
}

/* ---------- module grid ---------- */
static unsigned char mod[MAX_SIZE][MAX_SIZE];
static unsigned char fun[MAX_SIZE][MAX_SIZE];
static int size;

static void set_fun(int x, int y, int dark)
{
	mod[y][x] = (unsigned char)(dark ? 1 : 0);
	fun[y][x] = 1;
}

static void draw_finder(int cx, int cy)
{
	for (int dy = -4; dy <= 4; dy++)
		for (int dx = -4; dx <= 4; dx++) {
			int d = dx < 0 ? -dx : dx, e = dy < 0 ? -dy : dy;
			int dist = d > e ? d : e;
			int x = cx + dx, y = cy + dy;
			if (x >= 0 && x < size && y >= 0 && y < size)
				set_fun(x, y, dist != 2 && dist != 4);
		}
}

static void draw_align(int cx, int cy)
{
	for (int dy = -2; dy <= 2; dy++)
		for (int dx = -2; dx <= 2; dx++) {
			int d = dx < 0 ? -dx : dx, e = dy < 0 ? -dy : dy;
			set_fun(cx + dx, cy + dy, (d > e ? d : e) != 1);
		}
}

static void draw_format(int mask)
{
	int data = (1 << 3) | mask;      /* ecc level L = 0b01 */
	int rem = data;
	for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
	int bits = ((data << 10) | rem) ^ 0x5412;
#define BIT(i) (((bits >> (i)) & 1) != 0)
	for (int i = 0; i <= 5; i++) set_fun(8, i, BIT(i));
	set_fun(8, 7, BIT(6));
	set_fun(8, 8, BIT(7));
	set_fun(7, 8, BIT(8));
	for (int i = 9; i < 15; i++) set_fun(14 - i, 8, BIT(i));
	for (int i = 0; i < 8; i++) set_fun(size - 1 - i, 8, BIT(i));
	for (int i = 8; i < 15; i++) set_fun(8, size - 15 + i, BIT(i));
	set_fun(8, size - 8, 1);          /* always-dark module */
#undef BIT
}

/* ---------- bit stream ---------- */
static unsigned char code[MAX_CODE];   /* data codewords then ecc codewords */

static void place_codewords(int ncode)
{
	int i = 0;
	for (int right = size - 1; right >= 1; right -= 2) {
		if (right == 6) right = 5;
		for (int vert = 0; vert < size; vert++) {
			for (int j = 0; j < 2; j++) {
				int x = right - j;
				int upward = ((right + 1) & 2) == 0;
				int y = upward ? size - 1 - vert : vert;
				if (!fun[y][x] && i < ncode * 8) {
					mod[y][x] = (unsigned char)((code[i >> 3] >> (7 - (i & 7))) & 1);
					i++;
				}
			}
		}
	}
}

static void apply_mask(int msk)
{
	for (int y = 0; y < size; y++)
		for (int x = 0; x < size; x++) {
			int inv;
			switch (msk) {
			case 0: inv = (x + y) % 2 == 0; break;
			case 1: inv = y % 2 == 0; break;
			case 2: inv = x % 3 == 0; break;
			case 3: inv = (x + y) % 3 == 0; break;
			case 4: inv = (x / 3 + y / 2) % 2 == 0; break;
			case 5: inv = (x * y) % 2 + (x * y) % 3 == 0; break;
			case 6: inv = ((x * y) % 2 + (x * y) % 3) % 2 == 0; break;
			default: inv = ((x + y) % 2 + (x * y) % 3) % 2 == 0; break;
			}
			if (inv && !fun[y][x]) mod[y][x] ^= 1;
		}
}

/* penalty rules 1, 2 and 4 (rule 3 skipped: it only tunes which of 8 decodable masks wins) */
static long penalty(void)
{
	long p = 0;
	for (int y = 0; y < size; y++) {
		for (int x = 0; x < size; x++) {
			int c = mod[y][x];
			if (x + 1 < size && y + 1 < size &&
			    c == mod[y][x + 1] && c == mod[y + 1][x] && c == mod[y + 1][x + 1])
				p += 3;
			if (x + 4 < size) {
				int same = 1;
				for (int k = 1; k < 5; k++) if (mod[y][x + k] != c) same = 0;
				if (same) p += 3;
			}
			if (y + 4 < size) {
				int same = 1;
				for (int k = 1; k < 5; k++) if (mod[y + k][x] != c) same = 0;
				if (same) p += 3;
			}
		}
	}
	int dark = 0;
	for (int y = 0; y < size; y++)
		for (int x = 0; x < size; x++) dark += mod[y][x];
	int pct = dark * 100 / (size * size);
	int k = (pct - 50) / 5;
	if (k < 0) k = -k;
	return p + k * 10;
}

int qr_encode_mask(const char *text, int force_mask, unsigned char *out)
{
	if (!gf_ready) gf_init();
	int n = (int)strlen(text);
	int v = -1;
	for (int i = 0; i < NVER; i++)
		if (n <= VER[i].cap) { v = i; break; }
	if (v < 0) return -1;

	size = VER[v].size;
	int ndata = VER[v].data, nec = VER[v].ecc, ncode = ndata + nec;
	memset(mod, 0, sizeof mod);
	memset(fun, 0, sizeof fun);
	memset(code, 0, sizeof code);

	/* --- data codewords --- */
	{
		unsigned char bits[MAX_CODE * 8];
		int nb = 0;
#define PUT(val, len) do { for (int _i = (len) - 1; _i >= 0; _i--) bits[nb++] = (unsigned char)(((val) >> _i) & 1); } while (0)
		PUT(0x4, 4);                 /* byte mode */
		PUT(n, 8);                   /* char count, 8 bits for versions 1-9 */
		for (int i = 0; i < n; i++) PUT((unsigned char)text[i], 8);
#undef PUT
		int cap_bits = ndata * 8;
		int term = cap_bits - nb;
		if (term > 4) term = 4;
		for (int i = 0; i < term; i++) bits[nb++] = 0;
		while (nb % 8) bits[nb++] = 0;
		for (int i = 0, b = 0; i < nb; i += 8, b++) {
			int byte = 0;
			for (int j = 0; j < 8; j++) byte = (byte << 1) | bits[i + j];
			code[b] = (unsigned char)byte;
		}
		for (int b = nb / 8, alt = 0; b < ndata; b++, alt++)
			code[b] = (unsigned char)(alt % 2 ? 0x11 : 0xEC);
	}
	rs_ecc(code, ndata, nec, code + ndata);

	/* --- function patterns (must exist before placing codewords) --- */
	for (int i = 0; i < size; i++) {
		set_fun(6, i, i % 2 == 0);
		set_fun(i, 6, i % 2 == 0);
	}
	draw_finder(3, 3);
	draw_finder(size - 4, 3);
	draw_finder(3, size - 4);
	if (v >= 1) draw_align(size - 7, size - 7);
	draw_format(0);              /* placeholder: reserves the format modules */

	place_codewords(ncode);

	/* --- pick a mask (format bits are redrawn per candidate; the codewords are already placed) --- */
	if (force_mask >= 0 && force_mask < 8) {
		apply_mask(force_mask);
		draw_format(force_mask);
	} else {
		unsigned char best[MAX_SIZE][MAX_SIZE];
		long best_p = -1;
		for (int m = 0; m < 8; m++) {
			apply_mask(m);
			draw_format(m);
			long p = penalty();
			if (best_p < 0 || p < best_p) {
				best_p = p;
				memcpy(best, mod, sizeof mod);
			}
			apply_mask(m);       /* XOR again to undo */
		}
		memcpy(mod, best, sizeof mod);
	}

	for (int y = 0; y < size; y++)
		for (int x = 0; x < size; x++)
			out[y * size + x] = mod[y][x];
	return size;
}

int qr_encode(const char *text, unsigned char *out)
{
	return qr_encode_mask(text, -1, out);
}
