#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "buildcheck: $SRC not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=""
for name in last_wine_build note_other_build claim_prefix; do
	body=$(extract "$name")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	functions="$functions
$body"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

np_support="$work/support"
clone() {
	inf="$np_support/runners/crossover-$1/CrossOver/share/wine/wine.inf"
	mkdir -p "$(dirname "$inf")"
	: > "$inf"
	touch -t "$2" "$inf"
}
clone 26.3.0.39832 202607151200
clone 27.0.0.40921-fex 202608211200
printf 'notproton\t27.0.0.40921-fex\tfex\tCrossOver Preview (FEX)\nnotproton-26.3\t26.3.0.39832\trosetta\tCrossOver 26.3\n' \
	> "$np_support/tools"
mtime() { stat -f %m "$np_support/runners/crossover-$1/CrossOver/share/wine/wine.inf"; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

launch() {
	build=$1 updated=$2 record=$3
	data=$(mktemp -d "$work/compatdata.XXXXXX")
	mkdir -p "$data/pfx"
	[ -z "$updated" ] || printf '%s\r\n' "$updated" > "$data/pfx/.update-timestamp"
	[ -z "$record" ] || printf '%s' "$record" > "$data/notproton-build"
	(
		STEAM_COMPAT_DATA_PATH=$data
		np_build=$build
		np_display="display of $build"
		CX_ROOT="$np_support/runners/crossover-$build/CrossOver"
		log="$data/log"
		# shellcheck disable=SC2329 # a switch must not raise a dialog
		show_alert() { printf 'alert: %s\n' "$2"; }
		eval "$functions"
		note_other_build
		claim_prefix
	) > "$data/out" 2>&1 && status=0 || status=$?
	echo "status=$status"
	cat "$data/out"
	grep -o 'last run by build [^=]*,' "$data/log" 2>/dev/null || true
	[ ! -f "$data/notproton-build" ] || head -1 "$data/notproton-build"
}

echo "== prefixes from before the record =="
is "a fresh prefix is claimed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "" "")"
is "a prefix this build last updated is claimed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "$(mtime 26.3.0.39832)" "")"
is "a prefix another clone updated runs and is claimed" "status=0
last run by build 27.0.0.40921-fex (CrossOver Preview (FEX)),
26.3.0.39832" "$(launch 26.3.0.39832 "$(mtime 27.0.0.40921-fex)" "")"
is "a prefix no clone updated runs and is claimed" "status=0
last run by build other (another version of CrossOver),
26.3.0.39832" "$(launch 26.3.0.39832 1 "")"
is "updates the user disabled say nothing, so the prefix is claimed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 disable "")"

clone 27.0.0.40921 202608211200
is "a prefix either of two clones updated names neither" "status=0
last run by build other (another version of CrossOver),
26.3.0.39832" "$(launch 26.3.0.39832 "$(mtime 27.0.0.40921)" "")"

echo "== prefixes with a record =="
is "the record wins over the Wine that updated the prefix" "status=0
27.0.0.40921-fex" "$(launch 27.0.0.40921-fex "$(mtime 26.3.0.39832)" "27.0.0.40921-fex
CrossOver Preview (FEX)
")"
is "an older build takes over a newer build's prefix" "status=0
last run by build 27.0.0.40921-fex (CrossOver Preview (FEX)),
26.3.0.39832" "$(launch 26.3.0.39832 "" "27.0.0.40921-fex
CrossOver Preview (FEX)
")"
is "a newer build takes over an older build's prefix" "status=0
last run by build 26.3.0.39832 (CrossOver 26.3),
27.0.0.40921-fex" "$(launch 27.0.0.40921-fex "" "26.3.0.39832
CrossOver 26.3
")"

echo "== alerts =="
alert=$(extract show_alert)
[ -n "$alert" ] || { echo "FAIL: show_alert not found in $SRC"; exit 1; }
data=$(mktemp -d "$work/compatdata.XXXXXX")
(
	verb=waitforexitandrun
	# shellcheck disable=SC2329 # show_alert runs this in place of the real dialog
	osascript() {
		if /usr/bin/lockf -s -t 0 "$data/.notproton-prefix.lock" true; then
			echo free > "$data/during-alert"
		else
			echo held > "$data/during-alert"
		fi
	}
	eval "$alert"
	exec 8>> "$data/.notproton-prefix.lock"
	/usr/bin/lockf -s -t 0 8
	show_alert "title" "message"
)
is "an open alert does not keep the prefix locked" "free" "$(cat "$data/during-alert" 2>/dev/null)"

if [ "$fails" -eq 0 ]; then
	echo "==> buildcheck: all assertions hold"
else
	echo "==> buildcheck: $fails failed"
	exit 1
fi
