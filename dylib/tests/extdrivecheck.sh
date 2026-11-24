#!/bin/sh
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "extdrivecheck: $SRC not present, skipped"; exit 0; }

body=$(sed -n '/^np_disk_value() {/,/^}/p;/^np_external_disk() {/,/^}/p;/^restart_for_drive() {/,/^}/p;/^map_external_drives() {/,/^}/p' "$SRC")
[ -n "$body" ] || { echo "FAIL: map_external_drives not found in $SRC"; exit 1; }
body='without_lock_fds() { printf "%s\n" "${1##*/} $2" >> "$restarts"; }
np_disk_info() { cat "$disks/${1##*/}.plist" 2>/dev/null; }
np_volume_paths() { for v in "$volumes"/*; do [ -d "$v" ] && printf "%s\n" "$v"; done; }
'"$body"

work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

volumes="$work/Volumes"
disks="$work/disks"
mkdir -p "$volumes" "$disks"

# disk <name> <uuid> [internal] [removable] [bus]
disk() {
	mkdir -p "$volumes/$1"
	cat > "$disks/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>MountPoint</key><string>$volumes/$1</string>
<key>VolumeUUID</key><string>$2</string>
<key>Internal</key><${3:-false}/>
<key>RemovableMedia</key><${4:-false}/>
<key>BusProtocol</key><string>${5:-USB}</string>
</dict></plist>
PLIST
}
unplug() { rm -rf "${volumes:?}/$1" "$disks/$1.plist"; }

game() {
	compat="$work/compatdata/$1"
	[ -d "$compat/pfx" ] && return 0
	mkdir -p "$compat/pfx/dosdevices"
	ln -s ../drive_c "$compat/pfx/dosdevices/c:"
}
run() {
	game "$1"
	: > "$work/log"
	: > "$work/restarts"
	env restarts="$work/restarts" disks="$disks" volumes="$volumes" WINESERVER=/runner/wineserver \
		WINEPREFIX="$compat/pfx" STEAM_COMPAT_DATA_PATH="$compat" log="$work/log" app_id="$1" body="$body" \
		NOTPROTON_EXTERNAL_DRIVES="${2-}" \
		sh -ec 'eval "$body"; [ -n "$NOTPROTON_EXTERNAL_DRIVES" ] || unset NOTPROTON_EXTERNAL_DRIVES; map_external_drives; echo reached' \
		> "$work/out" 2>&1 || true
}
at() { readlink "$work/compatdata/$1/pfx/dosdevices/$2:" 2>/dev/null || echo none; }
record() { cut -f1,2 "$work/compatdata/$1/notproton-drive-letters" 2>/dev/null | tr '\t\n' ': ' || true; }
restarted() { tr '\n' ' ' < "$work/restarts"; }

a=3000000001
b=3000000002

disk LaCie 353CB2E4-83EC-44B1-AC6F-D7BDFCDF1AEA
disk "Samsung T7" 0F0F0F0F-1111-2222-3333-444444444444
disk Stick AAAAAAAA-0000-0000-0000-000000000001 false true
disk Installer AAAAAAAA-0000-0000-0000-000000000002 false false "Disk Image"
disk Inside AAAAAAAA-0000-0000-0000-000000000003 true
ln -s / "$volumes/Macintosh HD"

echo "== a non-Steam game gives each external disk a letter"
run $a
is "LaCie is E:" "$volumes/LaCie" "$(at $a e)"
is "the Samsung is F:" "$volumes/Samsung T7" "$(at $a f)"
is "a USB stick gets none" none "$(at $a g)"
is "the letters are recorded" "353CB2E4-83EC-44B1-AC6F-D7BDFCDF1AEA:e 0F0F0F0F-1111-2222-3333-444444444444:f " "$(record $a)"
is "wine restarts to see them" "wineserver -k wineserver -w " "$(restarted)"
is "the launch continues" reached "$(tail -1 "$work/out")"
is "no disk image, internal disk or boot volume got a letter" "" \
	"$(for d in "$work/compatdata/$a/pfx/dosdevices"/*; do case "${d##*/}" in (c:|e:|f:) ;; (*) echo "${d##*/}" ;; esac; done)"

echo "== a second launch leaves them alone"
run $a
is "LaCie is still E:" "$volumes/LaCie" "$(at $a e)"
is "nothing is logged" "" "$(cat "$work/log")"
is "wine is not restarted" "" "$(restarted)"

echo "== another game keeps letters of its own"
game $b
ln -s /tmp "$work/compatdata/$b/pfx/dosdevices/e:"
run $b
is "its own E: is kept" /tmp "$(at $b e)"
is "LaCie is F: there" "$volumes/LaCie" "$(at $b f)"
is "the Samsung is G: there" "$volumes/Samsung T7" "$(at $b g)"
is "the first game is untouched" "$volumes/LaCie" "$(at $a e)"

echo "== an unplugged disk loses its link and keeps its letter"
unplug LaCie
run $a
is "no E:" none "$(at $a e)"
is "the Samsung stays F:" "$volumes/Samsung T7" "$(at $a f)"
is "E: is still LaCie's" "353CB2E4-83EC-44B1-AC6F-D7BDFCDF1AEA:e 0F0F0F0F-1111-2222-3333-444444444444:f " "$(record $a)"
is "wine restarts to drop it" "wineserver -k wineserver -w " "$(restarted)"

echo "== a new disk does not take the unplugged one's letter"
disk Extra BBBBBBBB-0000-0000-0000-000000000001
run $a
is "the new disk is G:" "$volumes/Extra" "$(at $a g)"
is "E: stays free" none "$(at $a e)"
unplug Extra

echo "== the disk comes back under another name and gets its letter back"
disk "LaCie 1" 353CB2E4-83EC-44B1-AC6F-D7BDFCDF1AEA
run $a
is "E: is LaCie again" "$volumes/LaCie 1" "$(at $a e)"
is "the record follows it" "$volumes/LaCie 1" "$(grep '^353CB2E4' "$work/compatdata/$a/notproton-drive-letters" | cut -f3)"

echo "== a link someone else made is left alone"
rm -f "$work/compatdata/$a/pfx/dosdevices/f:"
ln -s /tmp "$work/compatdata/$a/pfx/dosdevices/f:"
run $a
is "F: still points at /tmp" /tmp "$(at $a f)"
is "it is logged" yes "$(grep -q 'drive f: is not ours' "$work/log" && echo yes || echo no)"
rm -f "$work/compatdata/$a/pfx/dosdevices/f:"
run $a

echo "== turned off, the links go and the letters stay"
run $a 0
is "no E:" none "$(at $a e)"
is "no F:" none "$(at $a f)"
is "the record is kept" "353CB2E4-83EC-44B1-AC6F-D7BDFCDF1AEA:e 0F0F0F0F-1111-2222-3333-444444444444:f BBBBBBBB-0000-0000-0000-000000000001:g " "$(record $a)"
run $a
is "turned back on, E: returns" "$volumes/LaCie 1" "$(at $a e)"
is "and F:" "$volumes/Samsung T7" "$(at $a f)"

echo "== a Steam game gets nothing"
run 1574480
is "no E:" none "$(at 1574480 e)"
is "no record" no "$([ -e "$work/compatdata/1574480/notproton-drive-letters" ] && echo yes || echo no)"
is "wine is not restarted" "" "$(restarted)"
is "the launch continues" reached "$(tail -1 "$work/out")"

echo "== a prefix without dosdevices yet is left for later"
mkdir -p "$work/compatdata/3000000003/pfx"
run 3000000003
is "no record yet" no "$([ -e "$work/compatdata/3000000003/notproton-drive-letters" ] && echo yes || echo no)"

if [ "$fails" -ne 0 ]; then
	echo "==> extdrivecheck: $fails check(s) failed"
	exit 1
fi
echo "==> extdrivecheck: non-Steam games give external disks letters of their own"
