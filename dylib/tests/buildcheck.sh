#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "buildcheck: $SRC not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=""
for name in alert_safe last_wine_build refuse_other_build claim_prefix; do
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
		log=/dev/null
		# shellcheck disable=SC2329 # called by the extracted refusal
		show_alert() { printf 'alert: %s\n' "$2"; }
		# shellcheck disable=SC2329
		rebuild_prefix() { show_alert "rebuild" "$1"; exit 1; }
		eval "$functions"
		refuse_other_build
		claim_prefix
	) > "$data/out" 2>&1 && status=0 || status=$?
	echo "status=$status"
	grep -o 'last run by [^,]*' "$data/out" || true
	[ ! -f "$data/notproton-build" ] || head -1 "$data/notproton-build"
}

echo "== prefixes from before the record =="
is "a fresh prefix is claimed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "" "")"
is "a prefix this build last updated is claimed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "$(mtime 26.3.0.39832)" "")"
is "a prefix another clone updated is refused and named" "status=1
last run by CrossOver Preview (FEX)" "$(launch 26.3.0.39832 "$(mtime 27.0.0.40921-fex)" "")"
is "a prefix no clone updated is refused" "status=1
last run by another version of CrossOver" "$(launch 26.3.0.39832 1 "")"
is "updates the user disabled say nothing, so the prefix is claimed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 disable "")"

clone 27.0.0.40921 202608211200
is "a prefix either of two clones updated names neither" "status=1
last run by another version of CrossOver" "$(launch 26.3.0.39832 "$(mtime 27.0.0.40921)" "")"

echo "== prefixes with a record =="
is "the record wins over the Wine that updated the prefix" "status=0
27.0.0.40921-fex" "$(launch 27.0.0.40921-fex "$(mtime 26.3.0.39832)" "27.0.0.40921-fex
CrossOver Preview (FEX)
")"
is "a record for another build is refused" "status=1
last run by CrossOver Preview (FEX)
27.0.0.40921-fex" "$(launch 26.3.0.39832 "" "27.0.0.40921-fex
CrossOver Preview (FEX)
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

echo "== rebuild choices =="
arch_functions="$(extract prefix_machine)
$(extract tool_name)
$(extract refuse_foreign_prefix)"
arch_data="$work/arch/pfx/drive_c/windows/system32"
mkdir -p "$arch_data"
dd if=/dev/zero bs=1 count=60 of="$arch_data/ntdll.dll" 2>/dev/null
# DOS header points at a PE header with the x86_64 machine word.
printf '\100\000\000\000PE\000\000\144\206' >> "$arch_data/ntdll.dll"
arch_case() {
	(
		WINEPREFIX="$work/arch/pfx" wine_unix="$1" log=/dev/null
		# shellcheck disable=SC2329
		rebuild_prefix() { printf 'rebuild: %s\n' "$1"; }
		eval "$arch_functions"
		refuse_foreign_prefix
	)
}
is "an architecture mismatch offers rebuilding" 'rebuild: This game originally ran under the Rosetta build of CrossOver, but the selected compatibility tool uses the FEX build of CrossOver.' "$(arch_case aarch64-unix)"
is "a matching architecture needs no rebuild" "" "$(arch_case x86_64-unix)"
rebuild=$(extract rebuild_prefix)
mkdir -p "$work/app with spaces"
cat > "$work/app with spaces/NotProtonApp" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$TEST_DATA/arguments"
/usr/bin/lockf -s -t 0 "$TEST_DATA/.notproton-prefix.lock" true || exit 66
exit "$TEST_STATUS"
SH
chmod +x "$work/app with spaces/NotProtonApp"
printf '%s' "$work/app with spaces/NotProtonApp" > "$np_support/app-executable"

rebuild_case() {
	choice=$1 command_status=$2 launch_verb=$3
	data=$(mktemp -d "$work/compat data.XXXXXX")
	(
		export TEST_DATA="$data" TEST_STATUS="$command_status"
		STEAM_COMPAT_DATA_PATH=$data np_tool_dir=/tools/chosen np_build=selected-build np_flavor=rosetta
		np_display='Selected "tool" with \ and a newline
in its name'
		verb=$launch_verb log="$data/log"
		# shellcheck disable=SC2329
		osascript() { cat > "$data/prompt"; [ "$choice" != cancel ] || return 1; printf '%s\n' "$choice"; }
		# shellcheck disable=SC2329
		show_alert() { echo "$1" >> "$data/alerts"; }
		# shellcheck disable=SC2329
		prepare_prefix_directory() { exec 8>> "$data/.notproton-prefix.lock"; /usr/bin/lockf -s -t 0 8; echo locked >> "$data/checks"; }
		# shellcheck disable=SC2329
		refuse_other_build() { echo build >> "$data/checks"; }
		# shellcheck disable=SC2329
		refuse_foreign_prefix() { echo arch >> "$data/checks"; }
		eval "$rebuild"
		prepare_prefix_directory
		: > "$data/checks"
		rebuild_prefix 'Previous "tool" with \ and a newline
in its name'
		echo launched >> "$data/checks"
	) && status=0 || status=$?
}
rebuild_case 'Backup & Rebuild Prefix' 0 waitforexitandrun
is "backup rebuild succeeds with lock released for the app" 0 "$status"
is "selected tool and backup choice reach the app as arguments" "--rebuild-prefix
$data
chosen
selected-build
rosetta
keep-backup" "$(cat "$data/arguments")"
is "launch retakes its lock and rechecks both mismatches" "locked
build
arch
launched" "$(cat "$data/checks")"
rebuild_case 'Rebuild Prefix' 0 waitforexitandrun
is "rebuild without backup succeeds" 0 "$status"
is "rebuild without backup passes discard-backup" discard-backup "$(tail -1 "$data/arguments")"
rebuild_case cancel 0 waitforexitandrun
is "cancel stops the launch" 1 "$status"
is "cancel never calls the app" no "$([ -f "$data/arguments" ] && echo yes || echo no)"
rebuild_case 'Rebuild Prefix' 7 waitforexitandrun
is "a failed rebuild stops the launch" 1 "$status"
is "a failed rebuild never continues launch preparation" "" "$(cat "$data/checks")"
rebuild_case 'Rebuild Prefix' 0 run
is "install helpers refuse silently" 1 "$status"
is "install helpers never prompt" no "$([ -f "$data/prompt" ] && echo yes || echo no)"
printf '%s' "$work/missing" > "$np_support/app-executable"
rebuild_case 'Rebuild Prefix' 0 waitforexitandrun
is "a moved or missing app stops the launch" 1 "$status"
is "a missing app explains how to repair" 'NotProton app unavailable' "$(cat "$data/alerts")"

if [ "$fails" -eq 0 ]; then
	echo "==> buildcheck: all assertions hold"
else
	echo "==> buildcheck: $fails failed"
	exit 1
fi
