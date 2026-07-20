# -*- coding: utf-8 -*-
"""validate_inkb.py — structural safety check on injected Thai .inkb files.
For each file under payload/locales/<loc>: parse it, rebuild it (build_string_section +
patch_binary_offsets), and require byte-identical (idempotent). Also: re-decode every
string as UTF-8, and compare #strings + tail length against the English base file.
A file that fails any check could crash the game when that scene loads."""
import sys, pathlib, struct
ROOT = pathlib.Path(r"C:\Users\theze\Desktop\UntilThenModeThailanguse")
sys.path.insert(0, str(ROOT / "tools"))
import inkb_core as core
import oracle_patch

BASE = ROOT / "UntilThenExtrallPCK" / "assets" / "story"
PAYLOAD = ROOT / "ThaiMod" / "payload" / "assets" / "story" / "locales"

def _u32(b, i):
    return struct.unpack_from('<I', b, i)[0]

def _starts_map(strings):
    st = {}; off = 0
    for idx, s in enumerate(strings):
        st[off] = idx
        off += len(s['text'].encode('utf-8')) + 1
    return st

def orphan_check(rel, p, pb):
    """ด่าน orphan-string: ทุกสตริงต้องมีตัวชี้ ≥1. หา operand ที่หลุดการ repoint —
    ตำแหน่งใน base tail ที่ค่าเป็น string-start ของสตริงที่ oracle ไม่มีตัวชี้อื่นชี้เลย
    (สตริงกำพร้า) และใน payload ค่ายังค้างเป็นของ base + ไม่ตรง start ใหม่ = ตัวชี้พังแน่
    (เกมจะอ่านสตริงกลางตัวอักษร → ค้าง/เด้ง เช่นเคสฉากออดิชั่น 5/2 set_player_target).
    เจอเฉพาะไฟล์ n_official=0 (base ถูก patch หลัง localization) — ไฟล์อื่น oracle ครอบครบ."""
    btail = pb['binary_tail']; ttail = p['binary_tail']
    if len(btail) != len(ttail):
        return None  # tail-len mismatch มีด่านของตัวเองอยู่แล้ว
    bst = _starts_map(pb['strings'])
    tstart = set(_starts_map(p['strings']).keys())
    pos, _ = oracle_patch.operand_positions(rel)
    referenced = {_u32(btail, i) for i in pos}
    bad = []
    for i in range(len(btail) - 3):
        if i in pos:
            continue
        bv = _u32(btail, i)
        if bv == 0 or bv not in bst or bv in referenced:
            continue
        tv = _u32(ttail, i)
        if tv == bv and tv not in tstart:
            bad.append((i, bv, bst[bv]))
    return bad or None

def rebuild(data):
    p = core.parse_inkb(data)
    section, offmap = core.build_string_section(p['strings'])
    tail = core.patch_binary_offsets(p['binary_tail'], offmap)
    return p['header'] + section + tail, p

def validate_file(path, base_path, rel=None):
    data = path.read_bytes()
    try:
        rebuilt, p = rebuild(data)
    except Exception as e:
        return f"PARSE/REBUILD ERROR: {e}"
    if rebuilt != data:
        return f"NOT IDEMPOTENT (rebuild != file): len {len(data)} vs {len(rebuilt)}"
    # utf-8 validity of every string
    for i, s in enumerate(p['strings']):
        try:
            (s['text'] if isinstance(s, dict) else s).encode("utf-8")
        except Exception as e:
            return f"BAD UTF-8 in string {i}: {e}"
    # parity vs base
    if base_path.exists():
        pb = core.parse_inkb(base_path.read_bytes())
        if len(pb['strings']) != len(p['strings']):
            return f"STRING COUNT MISMATCH vs base: base {len(pb['strings'])} != {len(p['strings'])}"
        if len(pb['binary_tail']) != len(p['binary_tail']):
            return f"TAIL LEN MISMATCH vs base: base {len(pb['binary_tail'])} != {len(p['binary_tail'])}"
        # orphan-string gate: unpatched operand of a string nothing else points to
        if rel is not None:
            bad = orphan_check(rel, p, pb)
            if bad:
                i, bv, sidx = bad[0]
                stxt = pb['strings'][sidx]['text'][:40]
                return (f"ORPHAN OPERAND x{len(bad)}: pos={i} still points to base offset {bv} "
                        f"(str#{sidx} {stxt!r}) - game will read mid-string -> freeze/crash")
    return None  # OK

def main(locs=("th", "fil")):
    total = 0; ok = 0; fails = []
    for loc in locs:
        root = PAYLOAD / loc
        if not root.exists(): continue
        for f in root.rglob("*.inkb"):
            rel = f.relative_to(root)
            base_path = BASE / rel
            total += 1
            err = validate_file(f, base_path, rel=str(rel).replace("\\", "/"))
            if err is None: ok += 1
            else: fails.append((loc, str(rel), err))
    print(f"validated {total} files: {ok} OK, {len(fails)} FAILED")
    for loc, rel, err in fails[:40]:
        print(f"  [{loc}/{rel}] {err}")
    return len(fails)

if __name__ == "__main__":
    sys.exit(1 if main() else 0)
