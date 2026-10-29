#!/bin/sh
# Tests the plugin part of compat_run.sh.
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "featstagecheck: $SRC not present, skipped"; exit 0; }

block=$(sed -n '/^np_feat_dir=/,/^NP_FEAT_LIST$/p' "$SRC")
case "$block" in
  *np_feat_stage*np_feat_over*) ;;
  *) echo "FAIL: the plugin loop was not found in $SRC"; exit 1 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
feats="$work/Library/Application Support/notproton/plugins"
sys32="$work/pfx/drive_c/windows/system32"
mkdir -p "$work/stage" "$sys32" "$feats" "$work/lib"
printf 'ours\n' > "$work/stage/d3d11.dll"
printf 'ours\n' > "$work/stage/dxgi.dll"
printf 'dylib\n' > "$work/lib/feat.dylib"
printf '%s\n' "$block" > "$work/block.sh"

conf() {
  cat > "$feats/$1"
}
reset() {
  rm -f "$feats"/*.conf "$work"/pwned*
  restore
}
restore() {
  printf 'shipped\n' > "$sys32/d3d11.dll"
  rm -f "$sys32/dxgi.dll"
}
# Output: line 1 WINEDLLOVERRIDES, line 2 the dylibs, then the env lines.
run() {
  # shellcheck disable=SC2016 # expanded by the inner shell
  env -i PATH="$PATH" HOME="$work" np_support="$work/Library/Application Support/notproton" \
    log="$work/log" WINEPREFIX="$work/pfx" WINEDLLOVERRIDES="steamclient=n;lsteamclient=b" "$@" \
    sh -c 'set -e; . "$1/block.sh"; printf "%s\n%s\n%s" "$WINEDLLOVERRIDES" "$np_feat_dylibs" "$np_feat_envs"' \
    sh "$work"
}
line() {
  printf '%s\n' "$1" | sed -n "$2p"
}

fail=0
ok() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else
  echo "  FAIL  $1 (want [$3], got [$2])"; fail=1; fi; }

reset
conf 50-test.conf <<EOF
key = NOTPROTON_TESTFEAT
label = Test
section = dev
on = 1
stage = $work/stage
overrides = d3d11,dxgi=n
EOF
ln "$sys32/d3d11.dll" "$work/link.dll"
out=$(run NOTPROTON_TESTFEAT=1)
ok "the staged DLL replaces the shipped one" "$(cat "$sys32/d3d11.dll")" "ours"
ok "every file in the directory is staged" "$(cat "$sys32/dxgi.dll")" "ours"
ok "staging does not write through the old file" "$(cat "$work/link.dll")" "shipped"
ok "the overrides are appended, not assigned" "$(line "$out" 1)" "steamclient=n;lsteamclient=b;d3d11,dxgi=n"

inode=$(stat -f %i "$sys32/d3d11.dll")
run NOTPROTON_TESTFEAT=1 > /dev/null
ok "an unchanged DLL is left alone" "$(stat -f %i "$sys32/d3d11.dll")" "$inode"
printf 'clobbered\n' > "$sys32/d3d11.dll"
run NOTPROTON_TESTFEAT=1 > /dev/null
ok "a DLL a game overwrote is put back" "$(cat "$sys32/d3d11.dll")" "ours"

restore
out=$(run NOTPROTON_TESTFEAT=0)
ok "a plugin switched off stages nothing" "$(cat "$sys32/d3d11.dll")" "shipped"
ok "and adds no overrides" "$(line "$out" 1)" "steamclient=n;lsteamclient=b"

sed "s|^stage = .*|stage = $work/missing|" "$feats/50-test.conf" > "$work/x.conf"
mv -f "$work/x.conf" "$feats/50-test.conf"
out=$(run NOTPROTON_TESTFEAT=1)
ok "a missing stage directory still launches" "$(line "$out" 1)" "steamclient=n;lsteamclient=b;d3d11,dxgi=n"

reset
printf 'key = NOTPROTON_CR\r\nlabel = CR\r\non = 1 \r\noverrides = cr=n\r\n' > "$feats/10-cr.conf"
out=$(run NOTPROTON_CR=1)
ok "trailing whitespace and CR are trimmed" "$(line "$out" 1)" "steamclient=n;lsteamclient=b;cr=n"

reset
conf 10-first.conf <<EOF
key = NOTPROTON_DUP
label = First
overrides = first=n
EOF
conf 20-second.conf <<EOF
key = NOTPROTON_DUP
label = Second
overrides = second=n
EOF
out=$(run NOTPROTON_DUP=1)
ok "the first file for a key wins" "$(line "$out" 1)" "steamclient=n;lsteamclient=b;first=n"

reset
conf 10-nolabel.conf <<EOF
key = NOTPROTON_NOLABEL
overrides = nolabel=n
EOF
conf 20-section.conf <<EOF
key = NOTPROTON_SECTION
label = Section
section = other
overrides = section=n
EOF
out=$(run NOTPROTON_NOLABEL=1 NOTPROTON_SECTION=1)
ok "a plugin needs a label and the dev section" "$(line "$out" 1)" "steamclient=n;lsteamclient=b"

reset
conf 10-evil.conf <<EOF
key = NOTPROTON_A:-}\$(touch $work/pwned-key)\${X
label = Evil
EOF
conf 20-env.conf <<EOF
key = NOTPROTON_ENV
label = Env
env = AB\$(touch $work/pwned-env)=1
env = NOVALUE
env = lower=1
env = GOOD=a "b" \$(touch $work/pwned-value) \$HOME/x\$HOMEy
env = TILDE=~/build/a.dll
env = MID=a~/b
env = LATER=2
EOF
out=$(run NOTPROTON_ENV=1)
ok "a key is never evaluated" "$(find "$work" -name 'pwned*' | wc -l | tr -d ' ')" "0"
ok "env lines are kept newest first, with \$HOME filled in" \
  "$(line "$out" 3)|$(line "$out" 4)|$(line "$out" 5)|$(line "$out" 6)" \
  "LATER=2|MID=a~/b|TILDE=$work/build/a.dll|GOOD=a \"b\" \$(touch $work/pwned-value) $work/x${work}y"
ok "bad env names are logged" "$(grep -c 'NOTPROTON_ENV skips env' "$work/log")" "3"

reset
conf 10-parent.conf <<EOF
key = NOTPROTON_PARENT
label = Parent
requires = $work/lib/missing.dylib
requires = $work/lib/feat.dylib
inject = 1
EOF
conf 20-child.conf <<EOF
key = NOTPROTON_CHILD
label = Child
depends = NOTPROTON_PARENT
overrides = child=n
EOF
out=$(run NOTPROTON_PARENT=1 NOTPROTON_CHILD=1)
ok "the first existing requires is injected" "$(line "$out" 2)" "$work/lib/feat.dylib"
ok "a child of an active parent applies" "$(line "$out" 1)" "steamclient=n;lsteamclient=b;child=n"
out=$(run NOTPROTON_CHILD=1)
ok "a child of a parent switched off does not" "$(line "$out" 1)" "steamclient=n;lsteamclient=b"
rm -f "$work/lib/feat.dylib"
out=$(run NOTPROTON_PARENT=1 NOTPROTON_CHILD=1)
ok "nor does a child of a parent not installed" "$(line "$out" 1)|$(line "$out" 2)" "steamclient=n;lsteamclient=b|"
printf 'dylib\n' > "$work/lib/feat.dylib"

reset
conf 10-long.conf <<EOF
key = NOTPROTON_LONG
label = Long
on = 0123456789012345678901234567890123
overrides = long=n
EOF
conf 20-five.conf <<EOF
key = NOTPROTON_FIVE
label = Five
requires = m1
requires = m2
requires = m3
requires = m4
requires = $work/lib/feat.dylib
overrides = five=n
EOF
{ printf 'key = NOTPROTON_LINE\nlabel = Line\noverrides = line=n\n# '
  head -c 2100 /dev/zero | tr '\0' x; echo; } > "$feats/30-line.conf"
out=$(run NOTPROTON_LONG=0123456789012345678901234567890123 NOTPROTON_FIVE=1 NOTPROTON_LINE=1)
ok "long lines, long values and a fifth requires are refused" "$(line "$out" 1)" "steamclient=n;lsteamclient=b"

reset
conf B.conf <<EOF
key = NOTPROTON_ORDER
label = Upper
overrides = upper=n
EOF
conf a.conf <<EOF
key = NOTPROTON_ORDER
label = Lower
overrides = lower=n
EOF
out=$(run LANG=en_US.UTF-8 NOTPROTON_ORDER=1)
ok "files sort by byte, as in webpatch.c" "$(line "$out" 1)" "steamclient=n;lsteamclient=b;upper=n"

reset
mkdir -p "$work/co:lon"
printf 'dylib\n' > "$work/co:lon/feat.dylib"
conf 10-colon.conf <<EOF
key = NOTPROTON_COLON
label = Colon
requires = $work/co:lon/feat.dylib
inject = 1
EOF
out=$(run NOTPROTON_COLON=1)
ok "a dylib path with a colon is not loaded" "$(line "$out" 2)" ""

reset
conf 10-reserved.conf <<EOF
key = NOTPROTON_RES
label = Reserved
env = NOTPROTON_FEATURE_DYLIBS=/evil.dylib
env = WINEPREFIX=/elsewhere
env = DXVK_HUD=1
EOF
out=$(run NOTPROTON_RES=1)
ok "env cannot replace what the launcher sets" "$(line "$out" 3)|$(line "$out" 4)" "DXVK_HUD=1|"

reset
mkdir -p "$sys32/dxgi.dll"
conf 10-dir.conf <<EOF
key = NOTPROTON_DIR
label = Dir
stage = $work/stage
EOF
run NOTPROTON_DIR=1 > /dev/null
ok "staging skips a directory in the way" "$(find "$sys32/dxgi.dll" -type f | wc -l | tr -d ' ')|$(cat "$sys32/d3d11.dll")" "0|ours"
rmdir "$sys32/dxgi.dll"

# shellcheck disable=SC2016
feat_at=$(($(grep -n 'set -- --env "$np_feat_env" "$@"$' "$SRC" | cut -d: -f1) - 1))
feat_loop=$(sed -n "$feat_at,/^NP_FEAT_ENVS\$/p" "$SRC")
# shellcheck disable=SC2016 # Match the literal $(env.
forward_at=$(grep -n '^[[:space:]]*for name in $(env .*CX_APPLEGPTK' "$SRC" | cut -d: -f1)
ok "plugin env is prepended before the forwarded settings" "$([ "$feat_at" -lt "$forward_at" ] && echo yes)" "yes"
# shellcheck disable=SC2016 # expanded by the inner shell
args=$(np_feat_envs='LATER=2
GOOD=a b
' sh -c 'f=$1; set -- --args game; eval "$f"; printf "[%s]" "$@"' sh "$feat_loop" 2>&1 || true)
ok "plugin env reaches open in order" "$args" "[--env][GOOD=a b][--env][LATER=2][--args][game]"

# shellcheck disable=SC2016 # Match the literal heredoc.
launcher=$(sed -n '/^[[:space:]]*cat > "\$loader_macos\/launcher" <<LAUNCHER$/,/^LAUNCHER$/p' "$SRC")
inject=$(loader_macos="$work" WINELOADER=x loader_root="$work" HOME="$work" \
  sh -c 'eval "$1"; sed -n "/^shim=/,/NOTPROTON_GAME_CWD/p" "$loader_macos/launcher"' sh "$launcher")
mkdir -p "$work/Library/Application Support/notproton"
: > "$work/Library/Application Support/notproton/overlay-shim.dylib"
# shellcheck disable=SC2016 # expanded by the inner shell
dyld=$(env -i HOME="$work" STEAM_DYLD_INSERT_LIBRARIES=/o.dylib NOTPROTON_FEATURE_DYLIBS=/f.dylib \
  sh -c 'eval "$1"; printf "%s|%s" "$DYLD_INSERT_LIBRARIES" "${NOTPROTON_OVERLAY_SHIM:+shim}"' sh "$inject")
ok "plugin dylibs load after the overlay" "$dyld" \
  "$work/Library/Application Support/notproton/overlay-shim.dylib:/o.dylib:/f.dylib|shim"
# shellcheck disable=SC2016 # expanded by the inner shell
dyld=$(env -i HOME="$work" NOTPROTON_FEATURE_DYLIBS=/f.dylib \
  sh -c 'eval "$1"; printf "%s|%s" "$DYLD_INSERT_LIBRARIES" "${NOTPROTON_OVERLAY_SHIM:+shim}"' sh "$inject")
ok "plugin dylibs load without the overlay shim" "$dyld" "/f.dylib|"

[ "$fail" -eq 0 ] || exit 1
echo "==> featstagecheck: plugins stage into the prefix and extend the overrides"
