/* Host-side check for qr.c: prints the symbol as '#'/'.' rows so it can be diffed against a
 * reference encoder (tools/screen/ref-qr.py, which uses python-qrcode with a forced mask).
 * Not part of the device build.   usage: test-qr <text> [mask] */
#include <stdio.h>
#include <stdlib.h>
#include "qr.h"

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: %s <text> [mask]\n", argv[0]); return 2; }
	int mask = argc > 2 ? atoi(argv[2]) : -1;
	unsigned char m[41 * 41];
	int n = qr_encode_mask(argv[1], mask, m);
	if (n < 0) { fprintf(stderr, "does not fit\n"); return 1; }
	printf("%d\n", n);
	for (int y = 0; y < n; y++) {
		for (int x = 0; x < n; x++) putchar(m[y * n + x] ? '#' : '.');
		putchar('\n');
	}
	return 0;
}
