#!/usr/bin/env bash
# Functional tape test: load a tape image through the monitor and check that
# what landed in RAM is byte-for-byte what the image says should be there.
#
#   ./tape_test.sh                          first block of mazy (~2.5 min)
#   ./tape_test.sh block <image> <name>     first block of any image
#   ./tape_test.sh full  <image> <name>     whole image, then run it (~30 min)
#   ./tape_test.sh fast  <image> <name>     first block with the default turbo (16x at 25 MHz)
#
# The load address is read out of the tape image, not assumed: different titles
# load to different places (MAZY at $1000, most of the rest at $2200), and
# dumping the wrong region makes the test compare zeros with zeros and pass
# without checking anything. The comparison also refuses to pass if the expected
# bytes are all zero, for the same reason.

set -u
cd "$(dirname "$0")"

EXE=./obj_dir/Vemu
[ -x "$EXE" ] || { echo "$EXE not built -- run make first" >&2; exit 1; }

mode="${1:-block}"
image="${2:-${BMJR_TAPES:-tapes}/mazy.s.bin}"
name="${3:-MAZY}"
[ -f "$image" ] || { echo "FAIL: $image not found" >&2; exit 1; }

# Where does this image load, and how much of it is there?
base=$(python3 - "$image" <<'PY'
import sys
img = open(sys.argv[1], 'rb').read()
p, n, lo = 0, len(img), None
while p < n:
    if img[p] == 0xFF:
        while p < n and img[p] == 0xFF: p += 1
    if p >= n or img[p] != 0x01:
        p += 1; continue
    p += 1
    hdr = img[p:p+12]; kind = hdr[0]
    size = hdr[11] or (0 if kind == 0 else 0x100)
    p += 12
    addr = (img[p] << 8) | img[p+1]; p += 3 + size + 2
    if kind == 0x01 and (lo is None or addr < lo): lo = addr
print(f"{lo:04X}" if lo is not None else "")
PY
)
[ -n "$base" ] || { echo "FAIL: $image has no binary blocks to check" >&2; exit 1; }

case "$mode" in
	full)  dump_len=600; dump_frame=14500; stop=15410; fast_tape=off
	       extra=(--send-keys '14600:G' --send-keys "14700:$base" --send-keys '14800: ' --screenshot 15400) ;;
	block) dump_len=100; dump_frame=1300;  stop=1310; fast_tape=off; extra=() ;;
	fast)  dump_len=100; dump_frame=600;   stop=610;  fast_tape=on;  extra=() ;;
	*)     echo "usage: $0 [block|full|fast] [image] [name]" >&2; exit 1 ;;
esac

rm -f memdump_*.bin
[ -n "${QUIET:-}" ] || echo "Loading $image as $name at \$$base ($mode) ..."

"$EXE" --headless --tape "$image" --fast-tape "$fast_tape" \
       --send-keys '75:MON\n' --send-keys '200:L' --send-keys "260:$name" --send-keys '340: ' \
       --dump-mem "$base:$dump_len@$dump_frame" \
       --stop-at-frame "$stop" ${extra[@]+"${extra[@]}"} >/dev/null 2>&1

dump=$(ls memdump_*.bin 2>/dev/null | head -1)
[ -n "$dump" ] || { echo "FAIL: no memory dump produced"; exit 1; }

python3 - "$image" "$dump" <<'PY'
import sys
image, dump = sys.argv[1], sys.argv[2]
img = open(image, 'rb').read()
p, n, expected = 0, len(img), {}
while p < n:
    if img[p] == 0xFF:
        while p < n and img[p] == 0xFF: p += 1
    if p >= n or img[p] != 0x01:
        p += 1; continue
    p += 1
    hdr = img[p:p+12]; kind = hdr[0]
    size = hdr[11] or (0 if kind == 0 else 0x100)
    p += 12
    addr = (img[p] << 8) | img[p+1]; p += 3
    payload = img[p:p+size]; p += size + 2
    if kind == 0x01:
        for i, b in enumerate(payload): expected[addr+i] = b

got  = open(dump, 'rb').read()
base = int(dump.split('_')[1], 16)
want = bytes(expected.get(base + i, 0) for i in range(len(got)))

# A region the image says nothing about compares zero-to-zero and would "pass"
# while proving nothing. Treat that as a broken test, not a success.
if not any(want):
    print(f"FAIL  ${base:04X}: tape image has no data for this region -- "
          f"nothing was actually checked")
    sys.exit(1)

same = sum(1 for a, b in zip(got, want) if a == b)
if same == len(got):
    print(f"PASS  ${base:04X}-${base+len(got)-1:04X}: {same}/{len(got)} bytes match the tape image")
    sys.exit(0)
bad = [i for i, (a, b) in enumerate(zip(got, want)) if a != b]
print(f"FAIL  ${base:04X}-${base+len(got)-1:04X}: {same}/{len(got)} match, "
      f"first bad at ${base+bad[0]:04X} (got ${got[bad[0]]:02X}, want ${want[bad[0]]:02X})")
sys.exit(1)
PY
