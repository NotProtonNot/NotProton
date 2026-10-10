#!/bin/sh
# SC2016: setup steps are single-quoted on purpose, to expand inside each fixture's home.
# shellcheck disable=SC2034,SC2154,SC2016
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "licensecheck: $SRC not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=$(extract license_state)
[ -n "$functions" ] || { echo "FAIL: license_state not found in $SRC"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Fixtures carry their own keypair, so the machine's own license and trial never answer.
CX_ROOT="$work/CrossOver"
mkdir -p "$CX_ROOT/share/crossover/data"
openssl genrsa -out "$work/key.pem" 2048 2>/dev/null
openssl rsa -in "$work/key.pem" -pubout -out "$CX_ROOT/share/crossover/data/tie.pub" 2>/dev/null
openssl genrsa -out "$work/other.pem" 2048 2>/dev/null

now=1800000000
day=86400
stamp() { date -j -u -r "$1" '+%Y-%m-%d %H:%M:%S +0000'; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# state <first run, or empty for none> <setup...>: a fresh home and system directory, the
# setup run against them, then license_state at the fixed clock.
state() {
	first_run=$1
	shift
	home=$(mktemp -d "$work/home.XXXXXX")
	mkdir -p "$home/Library/Preferences" "$home/system"
	(
		HOME=$home
		np_system_prefs="$home/system"
		np_now=$now
		# shellcheck disable=SC2329 # called by the extracted license_state
		defaults() { [ -n "$first_run" ] || return 1; printf '%s\n' "$first_run"; }
		for step in "$@"; do eval "$step"; done
		eval "$functions"
		license_state
	)
}

# license <dir> [key] [digest] [sidecar]: a license file, signed unless key is "none".
license() {
	printf '[license]\nid=test\n' > "$1/com.codeweavers.CrossOver.license"
	[ "${2:-$work/key.pem}" != none ] || return 0
	openssl dgst "${3:--sha256}" -sign "${2:-$work/key.pem}" \
		-out "$1/com.codeweavers.CrossOver.${4:-sha256}" "$1/com.codeweavers.CrossOver.license"
}

echo "== paid licenses =="
is "a license signed by the bundle's key is accepted" licensed \
	"$(state "" 'license "$HOME/Library/Preferences"')"
is "a .sig sidecar is accepted" licensed \
	"$(state "" 'license "$HOME/Library/Preferences" "$work/key.pem" -sha1 sig')"
is "a license in the system directory is accepted" licensed \
	"$(state "" 'license "$np_system_prefs"')"
is "a paid license is accepted after the trial has ended" licensed \
	"$(state "$(stamp $((now - 400 * day)))" 'license "$HOME/Library/Preferences"')"

echo "== licenses that fail =="
is "a license signed by another key is refused" unlicensed \
	"$(state "" 'license "$HOME/Library/Preferences" "$work/other.pem"')"
is "a failing license is not rescued by an active trial" unlicensed \
	"$(state "$(stamp $((now - day)))" 'license "$HOME/Library/Preferences" "$work/other.pem"')"
is "an unsigned license is not rescued by an active trial" unlicensed \
	"$(state "$(stamp $((now - day)))" 'license "$HOME/Library/Preferences" none')"

echo "== trials =="
is "an active trial says how many days are left" "trial 11" \
	"$(state "$(stamp $((now - 3 * day)))")"
is "half a day left rounds up to one" "trial 1" \
	"$(state "$(stamp $((now - 13 * day - day / 2)))")"
is "a trial ends at exactly 14 days" ended \
	"$(state "$(stamp $((now - 14 * day)))")"
is "a trial long past is ended" ended \
	"$(state "$(stamp $((now - 400 * day)))")"

echo "== trial state that cannot be read =="
is "no recorded first run is refused" unlicensed "$(state "")"
is "a first run in the future is refused" unlicensed \
	"$(state "$(stamp $((now + 60)))")"
is "a first run that is not a date is refused" unlicensed "$(state "not a date")"

[ "$fails" -eq 0 ] || { echo "==> licensecheck: $fails failed"; exit 1; }
echo "==> licensecheck: launch-time license and trial rule holds"
