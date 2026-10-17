#!/usr/bin/env python3
"""Build changxing60.zh-cn.lmo from tools/i18n/zh-cn.json.

The resulting catalog sits next to the official base.zh-cn.lmo under
/usr/lib/lua/luci/i18n/ . The LuCI loader (lmo_load_catalog) scans that dir
for `*.zh-cn.lmo` and loads every match, so this one file covers all five
changxing60 views' _() strings that base doesn't already translate.

Usage:
  python3 tools/i18n/build-i18n.py [out.lmo] [--verify base.zh-cn.lmo]

With --verify, also confirms that each msgid we translate is NOT already
covered by base (so we aren't duplicating / overriding the official pack),
and that re-decoding our output yields the same msgid->msgstr mapping.
"""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from lmo import build_entry, encode_lmo, decode_lmo, canon_key_id

TABLE = os.path.join(HERE, 'zh-cn.json')
DEFAULT_OUT = os.path.join(HERE, 'changxing60.zh-cn.lmo')

def load_table():
    d = json.load(open(TABLE, encoding='utf-8'))
    d.pop('_comment', None)
    return d

def build(out_path):
    table = load_table()
    entries = []
    skipped = []
    for msgid, msgstr in table.items():
        e = build_entry(msgid, msgstr)
        if e is None:
            skipped.append(msgid)
        else:
            entries.append(e)
    blob = encode_lmo(entries)
    with open(out_path, 'wb') as f:
        f.write(blob)
    print("wrote %s  (%d entries, %d bytes, %d untranslated-skipped)" % (
        out_path, len(entries), len(blob), len(skipped)))
    if skipped:
        print("  skipped (msgstr==msgid):", skipped)
    return table, blob

def verify(table, blob, base_path=None):
    # round-trip: decode our lmo, rebuild the msgid->msgstr map by re-hashing
    decoded = decode_lmo(blob)
    built_map = {kid: val for (kid, _vid, val) in decoded}
    ok = True
    checked = 0
    for msgid, msgstr in table.items():
        # skip intentionally-untranslated entries (msgstr == msgid): build_entry
        # returns None for them, the loader returns the key as-is, which is the
        # desired output, so they're correctly absent from the catalog.
        if build_entry(msgid, msgstr) is None:
            continue
        checked += 1
        kid = canon_key_id(msgid)
        vb = msgstr.encode('utf-8')
        if built_map.get(kid) != vb:
            print("  VERIFY FAIL: msgid %r -> kid %08x got %r want %r" % (
                msgid, kid, built_map.get(kid), vb))
            ok = False
    print("  self round-trip: %d/%d translated entries decode-correct" % (checked, checked) if ok
          else "  self round-trip: FAILED (see above)")
    if base_path and os.path.exists(base_path):
        base = decode_lmo(open(base_path, 'rb').read())
        base_kids = set(e[0] for e in base)
        overlap = [m for m in table if canon_key_id(m) in base_kids]
        print("  base overlap: %d of our msgids are ALSO in base (would be redundant)" % len(overlap))
        if overlap:
            print("    ", overlap[:10])
    return ok

def main():
    args = sys.argv[1:]
    out = DEFAULT_OUT
    base = None
    for i, a in enumerate(args):
        if a == '--verify' and i + 1 < len(args):
            base = args[i + 1]
        elif not a.startswith('--'):
            out = a
    # default base lookup: sibling overlay copy
    if base is None:
        cand = os.path.join(HERE, '..', '..', 'openwrt', 'overlay',
                            'usr', 'lib', 'lua', 'luci', 'i18n', 'base.zh-cn.lmo')
        if os.path.exists(cand):
            base = os.path.abspath(cand)
    table, blob = build(out)
    verify(table, blob, base)
    # sanity: show a few sample lookups the way the loader would resolve them
    print("  sample lookups:")
    for m in ['Dial', 'Incoming call from %s (%s)', 'Bandwidth', '短信'[:0] or 'SMS forwarding']:
        kid = canon_key_id(m)
        vb = next((v for (k, _v, v) in decode_lmo(blob) if k == kid), None)
        print("    %r -> %r" % (m, vb.decode('utf-8') if vb else '(MISSING)'))

if __name__ == '__main__':
    main()
