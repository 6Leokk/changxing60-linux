#!/usr/bin/env python3
"""Build an SMS-DELIVER PDU, host-side only, to test tools/.../sms-pdu.awk from the other side.

The device's codec decodes what the network sends; it only *encodes* SMS-SUBMIT, because that is all a phone
ever sends. So nothing on the device can produce a DELIVER for the decoder to be checked against, and a
round-trip through the device's own encoder would test one implementation against itself. This writes the
PDU independently -- GSM 03.38 alphabet, septet packing and the concatenation IE are all implemented here
from the spec, not imported -- so a disagreement between the two means one of them is wrong.

    usage: deliver.py <number> <text> [ref total part]     (ref/total/part: a long message)

DCS is chosen the way the device's encoder chooses it: the GSM alphabet when every character is in it,
UCS2 otherwise.
"""
import sys

# 3GPP TS 23.038 default alphabet, as Unicode code points, in septet order.
GSM = [
    0x40, 0xA3, 0x24, 0xA5, 0xE8, 0xE9, 0xF9, 0xEC, 0xF2, 0xC7, 0x0A, 0xD8, 0xF8, 0x0D, 0xC5, 0xE5,
    0x394, 0x5F, 0x3A6, 0x393, 0x39B, 0x3A9, 0x3A0, 0x3A8, 0x3A3, 0x398, 0x39E, 0x1B, 0xC6, 0xE6, 0xDF, 0xC9,
    0x20, 0x21, 0x22, 0x23, 0xA4, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
    0xA1, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F,
    0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0xC4, 0xD6, 0xD1, 0xDC, 0xA7,
    0xBF, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F,
    0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0xE4, 0xF6, 0xF1, 0xFC, 0xE0,
]
# the extension table, reached through 0x1B
EXT = {0x0C: 10, 0x5E: 20, 0x7B: 40, 0x7D: 41, 0x5C: 47, 0x5B: 60, 0x7E: 61, 0x5D: 62, 0x7C: 64, 0x65: 101}

FORWARD = {cp: i for i, cp in enumerate(GSM)}
FORWARD_EXT = {cp: s for s, cp in EXT.items()}


def septets(text):
    """text -> septet values, or None when a character is outside the alphabet."""
    out = []
    for ch in text:
        cp = ord(ch)
        if cp in FORWARD:
            out.append(FORWARD[cp])
        elif cp in FORWARD_EXT:
            out.extend((0x1B, FORWARD_EXT[cp]))
        else:
            return None
    return out


def pack(septs):
    """Seven-bit values into octets, the low bits of each first -- TS 23.040 9.2.2."""
    acc = 0
    bits = 0
    out = bytearray()
    for s in septs:
        acc |= s << bits
        bits += 7
        while bits >= 8:
            out.append(acc & 0xFF)
            acc >>= 8
            bits -= 8
    if bits:
        out.append(acc & 0xFF)
    return bytes(out)


def bcd_address(number):
    """A number as (length-in-digits, type-of-address, semi-octet BCD)."""
    intl = number.startswith('+')
    digits = number.lstrip('+')
    body = bytearray()
    for i in range(0, len(digits), 2):
        lo = digits[i]
        hi = digits[i + 1] if i + 1 < len(digits) else 'F'
        body.append(int(hi, 16) << 4 | int(lo, 16))
    return bytes([len(digits), 0x91 if intl else 0x81]) + bytes(body)


def scts(stamp):
    """'2026-10-13 09:41:07' -> the seven semi-octet bytes, time zone 00.

    Each byte holds two decimal digits with the low nibble first, which is the swap the device's
    decoder undoes -- so "26" becomes 0x62, not 0x26.
    """
    y, mo, day, h, mi, s = [int(x) for x in stamp.replace('-', ' ').replace(':', ' ').split()]
    out = bytearray()
    for v in ((y % 100), mo, day, h, mi, s, 0):
        out.append(((v % 10) << 4) | (v // 10))
    return bytes(out)


def udh(ref, total, part):
    """The concatenation element, preceded by UDHL -- the length of everything after it.

    UDHL counts the elements, not the octets of the whole header, and leaving it out is silent on the
    receiving side: a decoder reads a header length of 0 and then shows the element's own bytes as
    text in front of the message.
    """
    ie = bytes([0x00, 0x03, ref & 0xFF, total & 0xFF, part & 0xFF])
    return bytes([len(ie)]) + ie


def unpack(data, n):
    """Read n septets back out of a byte string; bits past its end read as 0."""
    out = []
    for i in range(n):
        bit = i * 7
        byte = bit // 8
        v = (data[byte] >> (bit % 8)) if byte < len(data) else 0
        if bit % 8 > 1:
            v |= (data[byte + 1] if byte + 1 < len(data) else 0) << (8 - bit % 8)
        out.append(v & 0x7F)
    return out


def deliver(number, text, ref=None, total=None, part=None, stamp='2026-10-13 09:41:07'):
    head = b'' if ref is None else udh(ref, total, part)
    sept = septets(text)
    if sept is not None:
        dcs = 0x00
        # The header rides in the same septet stream as the text, so it is read back as septets and the text
        # follows straight on. Whatever bits the header does not fill in its last septet are the filler the
        # decoder skips, which is why it counts them (ceil((udhl+1)*8/7)) rather than guessing.
        nhead = (len(head) * 8 + 6) // 7
        stream = unpack(head, nhead) + sept
        body = pack(stream)
        udl = len(stream)
    else:
        # UCS2 is octet aligned: the header counts in octets and the text starts straight after it
        dcs = 0x08
        body = head + text.encode('utf-16-be')
        udl = len(body)
    fo = 0x04 | (0x40 if head else 0x00)     # SMS-DELIVER, UDHI when a header is there
    pdu = b'\x00' + bytes([fo]) + bcd_address(number) + bytes([0x00, dcs]) + scts(stamp)
    pdu += bytes([udl]) + body
    return pdu.hex().upper()


if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        sys.exit(2)
    num, txt = sys.argv[1], sys.argv[2]
    if len(sys.argv) >= 6:
        print(deliver(num, txt, int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])))
    else:
        print(deliver(num, txt))
