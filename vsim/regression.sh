#!/usr/bin/env bash
# Screenshot regression for the Basic Master Jr. core.
#
#   ./regression.sh            screenshot scenarios + the tape load check
#   ./regression.sh boot       run one screenshot scenario by name
#   ./regression.sh --bless    accept the current screenshots as the new golden
#   ./regression.sh --no-tape  screenshots only (skips ~2.5 min of tape loading)
#
# Golden images live in regression_images/golden/, fresh runs land in
# regression_images/current/. A scenario fails if the PNG differs byte for
# byte; look at both images before blessing a change.
#
# The tape stage is a functional check, not a screenshot one: it loads a real
# tape image through the monitor and diffs what landed in RAM against what the
# image says should be there. A screenshot cannot express that -- the screen
# looks the same whether the bytes arrived correctly or not.
#
# Run from anywhere -- the script cd's to vsim/ itself, which is where the ROM
# .mem files have to be visible.

set -u
cd "$(dirname "$0")"

EXE=./obj_dir/Vemu
GOLDEN=regression_images/golden
CURRENT=regression_images/current

SCENARIOS="boot prompt basic_eval list_empty mon_enter"

# Fill `frame` and `args` for a scenario name.
setup_scenario() {
	args=()
	case "$1" in
		boot)       frame=60 ;;
		prompt)     frame=200; args=(--send-keys '75:PRINT 123') ;;
		basic_eval) frame=250; args=(--send-keys '75:PRINT 123\n') ;;
		list_empty) frame=200; args=(--send-keys '75:LIST\n') ;;
		mon_enter)  frame=250; args=(--send-keys '75:MON\n') ;;
		*) return 1 ;;
	esac
	return 0
}

bless=0
filter=""
run_tape=1
for arg in "$@"; do
	case "$arg" in
		--bless) bless=1 ;;
		--no-tape) run_tape=0 ;;
		-h|--help) sed -n '2,13p' "$0"; exit 0 ;;
		*) filter="$arg" ;;
	esac
done

if [ ! -x "$EXE" ]; then
	echo "$EXE not built -- run make first" >&2
	exit 1
fi

mkdir -p "$GOLDEN" "$CURRENT"

pass=0; fail=0; new=0

for name in $SCENARIOS; do
	[ -n "$filter" ] && [ "$filter" != "$name" ] && continue

	if ! setup_scenario "$name"; then
		echo "FAIL  $name  (unknown scenario)"
		fail=$((fail + 1))
		continue
	fi

	out="$CURRENT/$name.png"
	rm -f "$out"

	"$EXE" --headless \
	       --screenshot "$frame" --screenshot-name "$out" \
	       --stop-at-frame "$((frame + 10))" \
	       ${args[@]+"${args[@]}"} >/dev/null 2>&1   # empty-array-safe under set -u (bash 3.2)

	if [ ! -f "$out" ]; then
		echo "FAIL  $name  (no screenshot produced)"
		fail=$((fail + 1))
		continue
	fi

	if [ "$bless" = 1 ]; then
		cp "$out" "$GOLDEN/$name.png"
		echo "BLESS $name"
	elif [ ! -f "$GOLDEN/$name.png" ]; then
		cp "$out" "$GOLDEN/$name.png"
		echo "NEW   $name  (golden created -- eyeball $GOLDEN/$name.png)"
		new=$((new + 1))
	elif cmp -s "$out" "$GOLDEN/$name.png"; then
		echo "ok    $name"
		pass=$((pass + 1))
	else
		echo "FAIL  $name  ($out differs from $GOLDEN/$name.png)"
		fail=$((fail + 1))
	fi
done

# --- tape: functional, checks RAM against the image ---------------------------
# Skipped when a single scenario was named, or with --no-tape, or when blessing
# (there is nothing to bless -- the check is a byte comparison, not an image).
if [ "$run_tape" = 1 ] && [ -z "$filter" ] && [ "$bless" = 0 ]; then
	echo
	for t in "mazy.s.bin MAZY" "ascend.s.bin ASCEND"; do
		set -- $t
		img="${BMJR_TAPES:-tapes}/$1"
		if [ ! -f "$img" ]; then
			echo "SKIP  tape:$2  ($img not present)"
			continue
		fi
		if out=$(./tape_test.sh block "$img" "$2" 2>&1); then
			echo "ok    tape:$2  $(echo "$out" | tail -1 | sed 's/^PASS  //')"
			pass=$((pass + 1))
		else
			echo "FAIL  tape:$2"
			echo "$out" | tail -2 | sed 's/^/        /'
			fail=$((fail + 1))
		fi
	done
fi

echo
echo "$pass passed, $fail failed, $new new"
[ "$fail" -eq 0 ]
