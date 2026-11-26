#!/bin/sh
# Tests the plugin part of compat_run.sh.
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "featstagecheck: $SRC not present, skipped"; exit 0; }

# The loop reads descriptors through the shared reader, so that comes along with it.
conf=$(awk '/^np_conf_normalise\(\) \(/ { f = 1 }
            f { print }
            /^np_conf_log\(\) \{/ { g = 1 }
            g && /^}$/ { exit }' "$SRC")
block=$(sed -n '/^shortcut_game_id() {/,/^}$/p; /^np_feat_dir=/,/^np_feat_list=/p; /^np_env_reserved() {/,/^}$/p
                /^stage_step="plugins"$/,/^NP_FEAT_LIST$/p; /^np_plugin_host=/,/^game_cwd=/p' "$SRC")
case "$conf$block" in
  *np_conf_normalise*np_env_reserved*np_feat_stage*np_feat_over*np_plugin_host*) ;;
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
# shellcheck disable=SC2016 # expanded by the inner shell
stub='np_variant_read() { case " ${NP_TEST_VARIANTS:-} " in (*" $1 "*) return 0 ;; esac; return 1; }'
printf '%s\n%s\n%s\n' "$stub" "$conf" "$block" > "$work/block.sh"

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
    log="$work/log" WINEPREFIX="$work/pfx" WINEDLLOVERRIDES="steamclient=n;lsteamclient=b" \
    wine_unix="$work/x86_64-unix" "$@" \
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
[NOTPROTON_TESTFEAT]
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
printf '[NOTPROTON_CR]\r\nlabel = CR\r\non = 1 \r\noverrides = cr=n\r\n' > "$feats/10-cr.conf"
out=$(run NOTPROTON_CR=1)
ok "trailing whitespace and CR are trimmed" "$(line "$out" 1)" "steamclient=n;lsteamclient=b;cr=n"

reset
conf 10-first.conf <<EOF
[NOTPROTON_DUP]
label = First
overrides = first=n
EOF
conf 20-second.conf <<EOF
[NOTPROTON_DUP]
label = Second
overrides = second=n
EOF
out=$(run NOTPROTON_DUP=1)
ok "the first file for a key wins" "$(line "$out" 1)" "steamclient=n;lsteamclient=b;first=n"

reset
conf 10-nolabel.conf <<EOF
[NOTPROTON_NOLABEL]
overrides = nolabel=n
EOF
conf 20-section.conf <<EOF
[NOTPROTON_SECTION]
label = Section
section = other
overrides = section=n
EOF
out=$(run NOTPROTON_NOLABEL=1 NOTPROTON_SECTION=1)
ok "a plugin needs a label and the dev section" "$(line "$out" 1)" "steamclient=n;lsteamclient=b"

reset
conf 10-evil.conf <<EOF
[NOTPROTON_A:-}\$(touch $work/pwned-key)\${X]
label = Evil
EOF
conf 20-env.conf <<EOF
[NOTPROTON_ENV]
label = Env
env = GOOD=a "b" \$(touch $work/pwned-value) \$HOME/x\$HOMEy
env = TILDE=~/build/a.dll
env = MID=a~/b
env = LATER=2
EOF
# An env line that is not NAME=VALUE now loses the whole plugin rather than being
# skipped on its own: a plugin half-applied is worse than one that says it is refused.
conf 21-badenv.conf <<EOF
[NOTPROTON_BADENV]
label = Bad env
env = AB\$(touch $work/pwned-env)=1
overrides = bad=n
EOF
conf 22-noval.conf <<EOF
[NOTPROTON_NOVAL]
label = No value
env = NOVALUE
overrides = noval=n
EOF
out=$(run NOTPROTON_ENV=1 NOTPROTON_BADENV=1 NOTPROTON_NOVAL=1)
ok "a key is never evaluated" "$(find "$work" -name 'pwned*' | wc -l | tr -d ' ')" "0"
ok "env lines are kept newest first, with \$HOME filled in" \
  "$(line "$out" 3)|$(line "$out" 4)|$(line "$out" 5)|$(line "$out" 6)" \
  "LATER=2|MID=a~/b|TILDE=$work/build/a.dll|GOOD=a \"b\" \$(touch $work/pwned-value) $work/x${work}y"
ok "a plugin whose env line is not NAME=VALUE is refused whole" "$(line "$out" 1)" "steamclient=n;lsteamclient=b"
ok "and says which field lost it" \
   "$(grep -c 'refused, bad-value:env' "$work/log")" "2"

reset
conf 10-parent.conf <<EOF
[NOTPROTON_PARENT]
label = Parent
requires = $work/lib/missing.dylib
requires = $work/lib/feat.dylib
inject = 1
EOF
conf 20-child.conf <<EOF
[NOTPROTON_CHILD]
label = Child
depends = NOTPROTON_PARENT
overrides = child=n
EOF
conf 30-choice-parent.conf <<EOF
[NOTPROTON_CHOICE_PARENT]
label = Mode
type = choice
choice = fast = Fast
choice = quality = Quality
EOF
conf 40-choice-child.conf <<EOF
[NOTPROTON_CHOICE_CHILD]
label = Fast extra
depends = NOTPROTON_CHOICE_PARENT
overrides = fastchild=n
EOF
out=$(run NOTPROTON_PARENT=1 NOTPROTON_CHILD=1)
ok "the first existing requires is injected" "$(line "$out" 2)" "$work/lib/feat.dylib"
ok "a child of an active parent applies" "$(line "$out" 1)" "steamclient=n;lsteamclient=b;child=n"
out=$(run NOTPROTON_CHILD=1)
ok "a child of a parent switched off does not" "$(line "$out" 1)" "steamclient=n;lsteamclient=b"
out=$(run NOTPROTON_CHOICE_PARENT=quality NOTPROTON_CHOICE_CHILD=1)
ok "a child of a choice parent holding a value applies" "$(line "$out" 1)" "steamclient=n;lsteamclient=b;fastchild=n"
out=$(run NOTPROTON_CHOICE_CHILD=1)
ok "a child of a choice parent on Default does not" "$(line "$out" 1)" "steamclient=n;lsteamclient=b"
rm -f "$work/lib/feat.dylib"
out=$(run NOTPROTON_PARENT=1 NOTPROTON_CHILD=1)
ok "nor does a child of a parent not installed" "$(line "$out" 1)|$(line "$out" 2)" "steamclient=n;lsteamclient=b|"
printf 'dylib\n' > "$work/lib/feat.dylib"

reset
# A value is as long as a line allows now; only the line and the caps still bind.
conf 10-long.conf <<EOF
[NOTPROTON_LONG]
label = Long
on = 0123456789012345678901234567890123
overrides = long=n
EOF
conf 20-five.conf <<EOF
[NOTPROTON_FIVE]
label = Five
requires = m1
requires = m2
requires = m3
requires = m4
requires = $work/lib/feat.dylib
overrides = five=n
EOF
{ printf '[NOTPROTON_LINE]\nlabel = Line\noverrides = line=n\n# '
  head -c 2100 /dev/zero | tr '\0' x; echo; } > "$feats/30-line.conf"
out=$(run NOTPROTON_LONG=0123456789012345678901234567890123 NOTPROTON_FIVE=1 NOTPROTON_LINE=1)
ok "a long line and a fifth requires are refused, a long value is not" \
   "$(line "$out" 1)" "steamclient=n;lsteamclient=b;long=n"

reset
conf B.conf <<EOF
[NOTPROTON_ORDER]
label = Upper
overrides = upper=n
EOF
conf a.conf <<EOF
[NOTPROTON_ORDER]
label = Lower
overrides = lower=n
EOF
out=$(run LANG=en_US.UTF-8 NOTPROTON_ORDER=1)
ok "files sort by byte, as in webpatch.c" "$(line "$out" 1)" "steamclient=n;lsteamclient=b;upper=n"

reset
mkdir -p "$work/co:lon"
printf 'dylib\n' > "$work/co:lon/feat.dylib"
conf 10-colon.conf <<EOF
[NOTPROTON_COLON]
label = Colon
requires = $work/co:lon/feat.dylib
inject = 1
EOF
out=$(run NOTPROTON_COLON=1)
ok "a dylib path with a colon is not loaded" "$(line "$out" 2)" ""

reset
conf 10-reserved.conf <<EOF
[NOTPROTON_RES]
label = Reserved
env = NOTPROTON_FEATURE_DYLIBS=/evil.dylib
env = WINEPREFIX=/elsewhere
env = DXVK_HUD=1
EOF
out=$(run NOTPROTON_RES=1)
ok "env cannot replace what the launcher sets" "$(line "$out" 3)|$(line "$out" 4)" "DXVK_HUD=1|"

# The same names NOTPROTON_ENV_ is kept from, and no others: envpasscheck holds that side.
reset
conf 10-same.conf <<EOF
[NOTPROTON_SAME]
label = Same
env = HOME=/elsewhere
env = NOTPROTON_ANYTHING=1
env = WINEDEBUG=+loaddll
EOF
out=$(run NOTPROTON_SAME=1)
ok "env is kept from HOME and NOTPROTON_ as NOTPROTON_ENV_ is, and Wine's own settings pass" \
  "$(line "$out" 3)|$(line "$out" 4)" "WINEDEBUG=+loaddll|"

reset
conf 10-patha.conf <<EOF
[NOTPROTON_PATHA]
label = Path A
env = GST_PLUGIN_PATH=~/a
env = OTHER=1
EOF
conf 20-pathb.conf <<EOF
[NOTPROTON_PATHB]
label = Path B
env = GST_PLUGIN_PATH=~/b
env = OTHER=2
EOF
out=$(run NOTPROTON_PATHA=1 NOTPROTON_PATHB=1)
ok "two plugins setting one *_PATH get both folders" \
  "$(printf '%s\n' "$out" | grep -c '^GST_PLUGIN_PATH=')|$(printf '%s\n' "$out" | grep '^GST_PLUGIN_PATH=')" \
  "1|GST_PLUGIN_PATH=$work/a:$work/b"
ok "other variables still take the last value" "$(printf '%s\n' "$out" | grep -c '^OTHER=')" "2"
out=$(run NOTPROTON_PATHB=1)
ok "one plugin's *_PATH is left alone" "$(printf '%s\n' "$out" | grep '^GST_PLUGIN_PATH=')" "GST_PLUGIN_PATH=$work/b"

reset
mkdir -p "$sys32/dxgi.dll"
conf 10-dir.conf <<EOF
[NOTPROTON_DIR]
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
# A plugin may name the tools it is for, and the launch has to agree with the panel about
# it: a row hidden under one runner must not quietly apply there.
reset
conf 10-picky.conf <<EOF
[NOTPROTON_PICKY]
label = Picky
tools = notproton-fex*
overrides = picky=n
EOF
conf 20-any.conf <<EOF
[NOTPROTON_ANY]
label = Any
overrides = any=n
EOF
out=$(run np_tool_name=notproton-26.3 NOTPROTON_PICKY=1 NOTPROTON_ANY=1)
ok "a plugin for other tools does not apply" "$(line "$out" 1)" \
   "steamclient=n;lsteamclient=b;any=n"
out=$(run np_tool_name=notproton-fex-rosetta NOTPROTON_PICKY=1 NOTPROTON_ANY=1)
ok "and does on a tool its pattern matches" "$(line "$out" 1)" \
   "steamclient=n;lsteamclient=b;picky=n;any=n"

launcher() {
  # shellcheck disable=SC2016 # expanded by the inner shell
  env -i PATH="$PATH" HOME="$work" np_support="$work/Library/Application Support/notproton" \
    log="$work/log" WINEPREFIX="$work/pfx" verb=waitforexitandrun "$@" \
    sh -c 'set -e; . "$1/block.sh"; printf "%s" "$np_feat_launcher"' sh "$work"
}
printf 'exe\n' > "$work/lib/first.exe"
printf 'exe\n' > "$work/lib/second.exe"
reset
conf 10-first.conf <<EOF
[NOTPROTON_FIRST]
label = First
launcher = lib/first.exe
EOF
conf 20-second.conf <<EOF
[NOTPROTON_SECOND]
label = Second
launcher = lib/second.exe
EOF
conf 30-gone.conf <<EOF
[NOTPROTON_GONE]
label = Gone
launcher = lib/missing.exe
EOF
ok "a launcher is resolved from the home folder" "$(launcher NOTPROTON_SECOND=1)" "$work/lib/second.exe"
: > "$work/log"
ok "the first file's launcher wins" "$(launcher NOTPROTON_FIRST=1 NOTPROTON_SECOND=1)" "$work/lib/first.exe"
ok "and the log names the one that lost" "$(grep -c "NOTPROTON_SECOND's launcher is skipped" "$work/log")" "1"
ok "a launcher that isn't there is skipped" "$(launcher NOTPROTON_GONE=1)" ""
ok "a launcher is only used to start the game" "$(launcher NOTPROTON_FIRST=1 verb=run)" ""

present() {
  # shellcheck disable=SC2016 # expanded by the inner shell
  env -i PATH="$PATH" HOME="$work" np_support="$work/Library/Application Support/notproton" \
    log="$work/log" WINEPREFIX="$work/pfx" NOTPROTON_HERE=1 SteamGameId="$1" \
    sh -c 'set -e; b=$1; shift; . "$b/block.sh"; printf "%s" "$np_feat_envs"' sh "$work" "$2"
}
mkdir -p "$work/hub/games/A Game"
printf 'exe\n' > "$work/hub/launcher.exe"
printf 'exe\n' > "$work/hub/games/A Game/game.exe"
reset
conf 10-here.conf <<EOF
[NOTPROTON_HERE]
label = Here
present = games/*/game.exe
env = HERE=1
EOF
shortcut=12884901892328521728
ok "a shortcut with the file gets the row" \
  "$(present "$shortcut" "$work/hub/launcher.exe" | grep -c '^HERE=1$')" 1
ok "a shortcut without it doesn't" \
  "$(present "$shortcut" "$work/lib/first.exe" | grep -c '^HERE=1$')" 0
ok "neither does a Steam game, file or not" \
  "$(present 220240 "$work/hub/launcher.exe" | grep -c '^HERE=1$')" 0

# shellcheck disable=SC2016 # expanded by the inner shell
dyld=$(env -i HOME="$work" STEAM_DYLD_INSERT_LIBRARIES=/o.dylib NOTPROTON_FEATURE_DYLIBS=/f.dylib \
  sh -c 'eval "$1"; printf "%s|%s" "$DYLD_INSERT_LIBRARIES" "${NOTPROTON_OVERLAY_SHIM:+shim}"' sh "$inject")
ok "plugin dylibs load after the overlay" "$dyld" \
  "$work/Library/Application Support/notproton/overlay-shim.dylib:/o.dylib:/f.dylib|shim"
# shellcheck disable=SC2016 # expanded by the inner shell
dyld=$(env -i HOME="$work" NOTPROTON_FEATURE_DYLIBS=/f.dylib \
  sh -c 'eval "$1"; printf "%s|%s" "$DYLD_INSERT_LIBRARIES" "${NOTPROTON_OVERLAY_SHIM:+shim}"' sh "$inject")
ok "plugin dylibs load without the overlay shim" "$dyld" "/f.dylib|"

host="$work/Library/Application Support/notproton/plugin-host.dylib"
reset
conf 10-patch.conf <<EOF
[NOTPROTON_PATCHA]
label = Patch A
patch = winegstreamer.dll: 31 d2 e8 ?? 75=eb | 31 d2 e9 ?? 75=eb
patch = D3DMetal: 31=b0 c0=01 c3 90
[NOTPROTON_PATCHB]
label = Patch B
patch = winemac.drv: 48 8b 0b 41=42 b8
EOF
rm -f "$host"
: > "$work/log"
out=$(run NOTPROTON_PATCHA=1 NOTPROTON_PATCHB=1)
ok "patches without the plugin host load nothing" "$(line "$out" 2)|$(line "$out" 3)" "|"
ok "and the launch log says why" "$(grep -c "plugin-host.dylib is missing" "$work/log")" "1"
: > "$host"
out=$(run NOTPROTON_PATCHA=1 NOTPROTON_PATCHB=1)
ok "patches load the plugin host" "$(line "$out" 2)" "$host"
ok "and hand it every active plugin's patches" "$(line "$out" 3)" \
   "NOTPROTON_PLUGIN_PATCHES=NOTPROTON_PATCHA:winegstreamer.dll: 31 d2 e8 ?? 75=eb | 31 d2 e9 ?? 75=eb;NOTPROTON_PATCHA:D3DMetal: 31=b0 c0=01 c3 90;NOTPROTON_PATCHB:winemac.drv: 48 8b 0b 41=42 b8"
out=$(run NOTPROTON_PATCHA=1 NOTPROTON_PATCHB=0)
ok "a plugin switched off hands over none" "$(line "$out" 3)" \
   "NOTPROTON_PLUGIN_PATCHES=NOTPROTON_PATCHA:winegstreamer.dll: 31 d2 e8 ?? 75=eb | 31 d2 e9 ?? 75=eb;NOTPROTON_PATCHA:D3DMetal: 31=b0 c0=01 c3 90"
out=$(run NOTPROTON_PATCHA=0 NOTPROTON_PATCHB=0)
ok "no active patches load no host" "$(line "$out" 2)|$(line "$out" 3)" "|"

conf 20-inject.conf <<EOF
[NOTPROTON_INJECTED]
label = Injected
on = 1
inject = 1
requires = lib/feat.dylib
EOF
out=$(run NOTPROTON_PATCHA=0 NOTPROTON_PATCHB=0 NOTPROTON_INJECTED=1)
ok "inject plugin, no host" "$(line "$out" 2)" "$work/lib/feat.dylib"
out=$(run NOTPROTON_PATCHA=1 NOTPROTON_PATCHB=0 NOTPROTON_INJECTED=1)
ok "patches and inject plugin" "$(line "$out" 2)" "$host:$work/lib/feat.dylib"
: > "$host"
: > "$work/log"
out=$(run NOTPROTON_PATCHA=1 NOTPROTON_PATCHB=1 NOTPROTON_INJECTED=1 wine_unix="$work/aarch64-unix")
ok "FEX, no loader staged" "$(line "$out" 2)|$(printf '%s' "$out" | grep -c NOTPROTON_PLUGIN_LIBS)" "|0"
ok "logged" "$(grep -c "plugin loader isn't staged" "$work/log")" "1"
mkdir -p "$work/steam"
: > "$work/steam/npload.so"
out=$(run NOTPROTON_PATCHA=1 NOTPROTON_PATCHB=0 NOTPROTON_INJECTED=1 wine_unix="$work/aarch64-unix" \
  prefix_steam="$work/steam")
ok "FEX, nothing inserted" "$(line "$out" 2)" ""
ok "FEX, the patched ntdll gets the libraries" "$(line "$out" 3)" "NOTPROTON_PLUGIN_LIBS=$host:$work/lib/feat.dylib"
out=$(run NOTPROTON_PATCHA=0 NOTPROTON_PATCHB=0 NOTPROTON_INJECTED=0 wine_unix="$work/aarch64-unix" \
  prefix_steam="$work/steam")
ok "FEX, no plugins, no libraries" "$(printf '%s' "$out" | grep -c NOTPROTON_PLUGIN_LIBS)" "0"
shortcut=11221654761612771328
out=$(run NOTPROTON_PATCHA=0 NOTPROTON_PATCHB=0 NOTPROTON_INJECTED=0 wine_unix="$work/aarch64-unix" \
  prefix_steam="$work/steam" STEAM_DYLD_INSERT_LIBRARIES="$work/a.dylib:$work/b.dylib" SteamGameId=$shortcut NOTPROTON_FEX_OVERLAY=1)
ok "FEX shortcut, the overlay rides the plugin loader behind the shim" "$(line "$out" 3)" \
   "NOTPROTON_PLUGIN_LIBS=$work/Library/Application Support/notproton/overlay-shim.dylib:$work/a.dylib:$work/b.dylib"
out=$(run NOTPROTON_PATCHA=0 NOTPROTON_PATCHB=0 NOTPROTON_INJECTED=1 wine_unix="$work/aarch64-unix" \
  prefix_steam="$work/steam" STEAM_DYLD_INSERT_LIBRARIES="$work/a.dylib" SteamGameId=$shortcut NOTPROTON_FEX_OVERLAY=1)
ok "FEX shortcut, plugins load after the overlay" "$(line "$out" 3)" \
   "NOTPROTON_PLUGIN_LIBS=$work/Library/Application Support/notproton/overlay-shim.dylib:$work/a.dylib:$work/lib/feat.dylib"
out=$(run NOTPROTON_PATCHA=0 NOTPROTON_PATCHB=0 NOTPROTON_INJECTED=1 wine_unix="$work/aarch64-unix" \
  prefix_steam="$work/steam" STEAM_DYLD_INSERT_LIBRARIES="$work/a.dylib" SteamGameId=730 NOTPROTON_FEX_OVERLAY=1)
ok "FEX Steam game, the overlay is left to lsteamclient" "$(line "$out" 3)" \
   "NOTPROTON_PLUGIN_LIBS=$work/lib/feat.dylib"
out=$(run NOTPROTON_PATCHA=0 NOTPROTON_PATCHB=0 NOTPROTON_INJECTED=1 wine_unix="$work/aarch64-unix" \
  prefix_steam="$work/steam" STEAM_DYLD_INSERT_LIBRARIES="$work/a.dylib" SteamGameId=$shortcut)
ok "FEX shortcut, the overlay stays out unless it is turned on" "$(line "$out" 3)" \
   "NOTPROTON_PLUGIN_LIBS=$work/lib/feat.dylib"
out=$(run NOTPROTON_PATCHA=0 NOTPROTON_PATCHB=0 NOTPROTON_INJECTED=1 wine_unix="$work/aarch64-unix" \
  prefix_steam="$work/steam" STEAM_DYLD_INSERT_LIBRARIES="$work/a.dylib" SteamGameId=$shortcut NOTPROTON_FEX_OVERLAY=0)
ok "and a 0 keeps it out" "$(line "$out" 3)" "NOTPROTON_PLUGIN_LIBS=$work/lib/feat.dylib"
out=$(run NOTPROTON_PATCHA=0 NOTPROTON_PATCHB=0 NOTPROTON_INJECTED=0 wine_unix="$work/aarch64-unix" \
  prefix_steam="$work/steam" STEAM_DYLD_INSERT_LIBRARIES="$work/a.dylib" NOTPROTON_FEX_OVERLAY=1)
ok "FEX, no game ID, no overlay libraries" "$(printf '%s' "$out" | grep -c NOTPROTON_PLUGIN_LIBS)" "0"
: > "$work/log"
out=$(run NOTPROTON_PATCHA=0 NOTPROTON_PATCHB=0 NOTPROTON_INJECTED=0 wine_unix="$work/aarch64-unix" \
  STEAM_DYLD_INSERT_LIBRARIES="$work/a.dylib" SteamGameId=$shortcut NOTPROTON_FEX_OVERLAY=1)
ok "FEX shortcut without the loader says the overlay is off" \
   "$(printf '%s' "$out" | grep -c NOTPROTON_PLUGIN_LIBS)|$(grep -c "no overlay for this shortcut" "$work/log")" "0|1"
out=$(run NOTPROTON_PATCHA=0 NOTPROTON_PATCHB=0 NOTPROTON_INJECTED=0 prefix_steam="$work/steam" \
  STEAM_DYLD_INSERT_LIBRARIES="$work/a.dylib" SteamGameId=$shortcut NOTPROTON_FEX_OVERLAY=1)
ok "Rosetta, the overlay stays on the insert list" "$(printf '%s' "$out" | grep -c NOTPROTON_PLUGIN_LIBS)" "0"

reset
conf 10-variant.conf <<EOF
[NOTPROTON_VARFEAT]
label = Variant
stage = $work/stage
overrides = d3d11=n
variants = headset
EOF
: > "$work/log"
out=$(run NOTPROTON_VARFEAT=1)
ok "unusable variant stages nothing" "$(cat "$sys32/d3d11.dll")|$(line "$out" 1)" \
   "shipped|steamclient=n;lsteamclient=b"
ok "logged" \
   "$(grep -c "NOTPROTON_VARFEAT skipped, variant headset can't be used" "$work/log")" "1"
out=$(run NOTPROTON_VARFEAT=1 NP_TEST_VARIANTS=headset)
ok "usable variant stages" "$(cat "$sys32/d3d11.dll")|$(line "$out" 1)" \
   "ours|steamclient=n;lsteamclient=b;d3d11=n"

[ "$fail" -eq 0 ] || exit 1
echo "==> featstagecheck: plugins stage into the prefix and extend the overrides"
