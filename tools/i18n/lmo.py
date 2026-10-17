#!/usr/bin/env python3
"""lmo (Lua Machine Objects) encoder/decoder.

Direct port of openwrt/luci modules/luci-base/src/lib/{lmo.h,lmo.c} and
src/po2lmo.c (branch openwrt-23.05). Verified byte-compatible (semantically)
against the official luci-i18n-base-zh-cn catalog: decodes its 2307 entries,
re-hashes common msgids (Save/Network/System/Wireless/Firewall/Cancel/Hostnames)
and finds them in the released key-id set.

On-disk format (from lmo.h + po2lmo.c):
  file  =  [string blob] [index] [uint32 blob_size]
  - string blob: each value (UTF-8 bytes) then 0-padded to 4-byte alignment.
  - index: N * 16-byte entries (key_id, val_id, offset, length), each field
           big-endian (htonl), sorted ascending by key_id (loader binary-searches).
  - trailing uint32 = total blob size (== offset where the index starts), big-endian.

  key_id = lmo_canon_hash(msgid)   # see canon() below: collapse whitespace, then
                                   #   sfh_hash(canonical, len, len)  (seeded with length)
  val_id = plural_num + 1          # 1 for singular (NOT the value hash)
  Entries whose key_id == sfh_hash(value) are SKIPPED (untranslated: value == key).

The loader (lmo_load_catalog) scans i18ndir for `*.<lang>.lmo` and loads EVERY
matching archive, so one merged `changxing60.zh-cn.lmo` serves all our views
alongside the official `base.zh-cn.lmo`; no per-app split needed.
"""
import struct

# --- Paul Hsieh "SuperFastHash", seeded with the string length -----------------

def _sfh_get16(b, i):
    return b[i] | (b[i + 1] << 8)

def sfh_hash(data: bytes, init: int = None) -> int:
    if init is None:
        init = len(data)
    length = len(data)
    if length <= 0:
        return 0
    rem = length & 3
    n = length >> 2
    h = init & 0xFFFFFFFF
    i = 0
    for _ in range(n):
        h = (h + _sfh_get16(data, i)) & 0xFFFFFFFF
        tmp = ((_sfh_get16(data, i + 2) << 11) ^ h) & 0xFFFFFFFF
        h = ((h << 16) ^ tmp) & 0xFFFFFFFF
        i += 4
        h = (h + (h >> 11)) & 0xFFFFFFFF
    if rem == 3:
        h = (h + _sfh_get16(data, i)) & 0xFFFFFFFF
        h = (h ^ ((h << 16) & 0xFFFFFFFF)) & 0xFFFFFFFF
        sc = data[i + 2]
        if sc >= 128:
            sc -= 256
        h = (h ^ ((sc << 18) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 11)) & 0xFFFFFFFF
    elif rem == 2:
        h = (h + _sfh_get16(data, i)) & 0xFFFFFFFF
        h = (h ^ ((h << 11) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 17)) & 0xFFFFFFFF
    elif rem == 1:
        sc = data[i]
        if sc >= 128:
            sc -= 256
        h = (h + sc) & 0xFFFFFFFF
        h = (h ^ ((h << 10) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 1)) & 0xFFFFFFFF
    h = (h ^ ((h << 3) & 0xFFFFFFFF)) & 0xFFFFFFFF
    h = (h + (h >> 5)) & 0xFFFFFFFF
    h = (h ^ ((h << 4) & 0xFFFFFFFF)) & 0xFFFFFFFF
    h = (h + (h >> 17)) & 0xFFFFFFFF
    h = (h ^ ((h << 25) & 0xFFFFFFFF)) & 0xFFFFFFFF
    h = (h + (h >> 6)) & 0xFFFFFFFF
    return h

# --- whitespace canonicalization (port of lmo_canon_hash's non-ctx/plural path) -

def canon(s: str) -> str:
    """Collapse runs of whitespace to a single space and strip ends — exactly
    what the loader does before hashing, so our key_id matches its lookup."""
    out = []
    prev = ' '
    for c in s:
        if c.isspace():
            if not prev.isspace():
                out.append(' ')
        else:
            out.append(c)
        prev = c
    return ''.join(out).rstrip()

def canon_key_id(msgid: str) -> int:
    s = canon(msgid)
    sb = s.encode('utf-8')
    return sfh_hash(sb, len(sb))

# --- encode / decode -----------------------------------------------------------

def _pad4(n):
    return (4 - (n % 4)) % 4

def encode_lmo(entries):
    """entries: iterable of (key_id, val_id, value_bytes). Returns .lmo bytes.
    Entries are sorted by key_id (loader binary-searches)."""
    es = sorted(entries, key=lambda e: e[0])
    blob = bytearray()
    index = []
    for key_id, val_id, vbytes in es:
        offset = len(blob)
        length = len(vbytes)
        blob += vbytes
        blob += b'\x00' * _pad4(length)
        index.append((key_id, val_id, offset, length))
    out = bytearray()
    out += blob
    for key_id, val_id, offset, length in index:
        out += struct.pack('>IIII', key_id, val_id, offset, length)
    out += struct.pack('>I', len(blob))
    return bytes(out)

def decode_lmo(data: bytes):
    """Returns list of (key_id, val_id, value_bytes)."""
    if len(data) < 4:
        return []
    blob_size = struct.unpack('>I', data[-4:])[0]
    if blob_size > len(data) - 4:
        return []
    index_off = blob_size
    n = (len(data) - 4 - index_off) // 16
    out = []
    for i in range(n):
        key_id, val_id, offset, length = struct.unpack_from('>IIII', data, index_off + i * 16)
        out.append((key_id, val_id, data[offset:offset + length]))
    return out

def build_entry(msgid: str, msgstr: str):
    """One singular entry for msgid->msgstr, or None if untranslated (msgstr==msgid)."""
    vb = msgstr.encode('utf-8')
    kid = canon_key_id(msgid)
    if kid == sfh_hash(vb, len(vb)):
        return None
    return (kid, 1, vb)
