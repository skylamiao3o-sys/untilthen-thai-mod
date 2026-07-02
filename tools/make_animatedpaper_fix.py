#!/usr/bin/env python3
"""สร้าง payload/components/AnimatedPaper3D/AnimatedPaper3D.gd จาก base โดยแก้จุดเดียว:
บรรทัด set_custom_aabb(aabb) (sync) -> call_deferred (รันตอน idle = instance เป็น geometry แล้ว)
กัน crash instance_set_custom_aabb ในฉาก C3D_Window/SubViewport โดยยังคง culling ถูกต้อง.
+ เพิ่ม marker print ครั้งเดียว เพื่อยืนยันว่า build ใหม่ทำงาน."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
base = ROOT / "UntilThenExtrallPCK" / "components" / "AnimatedPaper3D" / "AnimatedPaper3D.gd"
dest = ROOT / "ThaiMod" / "payload" / "components" / "AnimatedPaper3D" / "AnimatedPaper3D.gd"

raw = base.read_bytes()
nl = b"\r\n" if b"\r\n" in raw else b"\n"
text = raw.decode("utf-8")
lines = text.split("\r\n") if nl == b"\r\n" else text.split("\n")

out = []
declared = False
patched = False
for ln in lines:
    # add the marker flag right after _refresh_anim declaration
    if not declared and ln.strip() == "var _refresh_anim := true":
        out.append(ln)
        out.append("var _tm_marked := false  # Thai Mod: verify fix active")
        declared = True
        continue
    # patch the crashing sync call
    if ln.strip() == "set_custom_aabb(aabb)  # TODO confirm correctness":
        indent = ln[:len(ln) - len(ln.lstrip())]  # leading tabs
        out.append(indent + "# Thai Mod fix: defer to idle. Calling set_custom_aabb synchronously crashes on")
        out.append(indent + "# this build when the rendering instance isn't a geometry instance yet (paper")
        out.append(indent + "# sprites inside the C3D_Window nested SubViewport). At idle the mesh base is set.")
        out.append(indent + "if not _tm_marked:")
        out.append(indent + "\t_tm_marked = true")
        out.append(indent + "\tprint(\"[TM] AnimatedPaper3D fix active: \", name)")
        out.append(indent + "if mesh != null:")
        out.append(indent + "\tcall_deferred(\"set_custom_aabb\", aabb)")
        patched = True
        continue
    out.append(ln)

assert declared, "did not find _refresh_anim declaration"
assert patched, "did not find set_custom_aabb(aabb) line"
dest.write_bytes((nl.decode() if False else ("\r\n" if nl==b"\r\n" else "\n")).join(out).encode("utf-8"))
print("wrote", dest)
print("declared marker:", declared, " patched call:", patched, " newline:", repr(nl))
# sanity
d = dest.read_text(encoding="utf-8")
print("has call_deferred set_custom_aabb:", 'call_deferred("set_custom_aabb"' in d)
print("has leftover sync call:", "set_custom_aabb(aabb)  # TODO" in d)
print("has editor reset (line656, ok/editor-only):", "set_custom_aabb(AABB())" in d)
