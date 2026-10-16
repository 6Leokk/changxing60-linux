/* Minimal QR encoder (byte mode, ECC level L, versions 1-5) for the status page.
 * See qr.c for why versions 1-5 and level L specifically. */
#ifndef CHANGXING60_QR_H
#define CHANGXING60_QR_H

/* Encode `text`; writes size*size bytes (1 = dark) into `out` (needs 41*41).
 * Returns the module count (e.g. 25 for version 2) or -1 if it does not fit. */
int qr_encode(const char *text, unsigned char *out);

/* Same, but with the mask forced (0-7). Only used by tools/screen/test-qr.c to diff our output
 * against a reference encoder one mask at a time; the page itself always calls qr_encode(). */
int qr_encode_mask(const char *text, int mask, unsigned char *out);

#endif
