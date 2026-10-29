#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "envcheck: $SRC not present, skipped"; exit 0; }

strip() { sed 's/^[[:space:]]*//'; }
dllpath_line=$(grep 'export WINEDLLPATH=' "$SRC" | grep 'x86_64-windows' | strip)
overrides_line=$(grep 'export WINEDLLOVERRIDES=' "$SRC" | grep 'lsteamclient=b' | strip)
[ -n "$dllpath_line" ] || { echo "FAIL: WINEDLLPATH merge not found"; exit 1; }
[ -n "$overrides_line" ] || { echo "FAIL: WINEDLLOVERRIDES merge not found"; exit 1; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

echo "== WINEDLLPATH (first match wins, runner first) =="
CX_ROOT=/R
wine_unix=/R/lib/wine/x86_64-unix
WINEDLLPATH=""
eval "$dllpath_line"
is "no user value" "/R/lib/wine/x86_64-windows:/R/lib/wine/x86_64-unix" "$WINEDLLPATH"
WINEDLLPATH="/user/dir"
eval "$dllpath_line"
is "user value last" "/R/lib/wine/x86_64-windows:/R/lib/wine/x86_64-unix:/user/dir" "$WINEDLLPATH"

echo "== WINEDLLOVERRIDES (last wins, trio last) =="
WINEDLLOVERRIDES=""
eval "$overrides_line"
is "no user value" "steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
WINEDLLOVERRIDES="winhttp=n,b"
eval "$overrides_line"
is "user value first" "winhttp=n,b;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
WINEDLLOVERRIDES="lsteamclient=n"
eval "$overrides_line"
is "trio outranks user" "lsteamclient=n;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
vc_overrides="vcruntime140_1=n,b;"
WINEDLLOVERRIDES="vcruntime140_1=b"
eval "$overrides_line"
is "user outranks the native runtime" \
  "vcruntime140_1=n,b;vcruntime140_1=b;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
vc_overrides=""

echo "== Microsoft's Visual C++ runtime loads when it is installed =="
vc_fn=$(sed -n '/^native_vc_runtime() {/,/^}/p' "$SRC")
[ -n "$vc_fn" ] || { echo "FAIL: native_vc_runtime not found"; exit 1; }
eval "$vc_fn"
vc_work=$(mktemp -d)
WINEPREFIX="$vc_work/pfx"
sys32="$WINEPREFIX/drive_c/windows/system32"
mkdir -p "$sys32"
pe() { printf 'MZ%062d%s' 0 "$2" > "$sys32/$1.dll"; }
is "empty prefix overrides nothing" "" "$(native_vc_runtime)"
pe vcruntime140 "Wine builtin DLL"
pe msvcp140_2 "Wine builtin DLL"
is "Wine's own copies are left alone" "" "$(native_vc_runtime)"
pe msvcp140_2 "This program cannot be run in DOS mode."
pe vcruntime140_1 "This program cannot be run in DOS mode."
: > "$sys32/msvcp140.dll"
is "Microsoft's copies load first" "msvcp140=n,b;msvcp140_2=n,b;vcruntime140_1=n,b;" "$(native_vc_runtime)"
rm -rf "$vc_work"

echo "== Apple GPTK initialization and launcher environment =="
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
np_support="$work/Application Support/notproton"
np_build="test"
library="$np_support/runners/crossover-$np_build/CrossOver/lib64/apple_gptk/external/libd3dshared.dylib"
init=$(sed -n '/^CX_ROOT=/,/^wine_unix=/p' "$SRC")
# shellcheck disable=SC2016 # Match the literal launcher loop.
forward=$(sed -n '/^ *for name in $(env .*CX_APPLEGPTK/,/^ *done$/p' "$SRC")
[ -n "$init" ] && [ -n "$forward" ] || { echo "FAIL: runner environment blocks not found"; exit 1; }
unset CX_APPLEGPTK_LIBD3DSHARED_PATH
eval "$init"
is "runner without the library leaves the path unset" "" "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}"
mkdir -p "$(dirname "$library")"
: > "$library"
eval "$init"
is "bundled library is selected" "$library" "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}"
is "helpers inherit the library path" "$library" "$(sh -c 'printf %s "$CX_APPLEGPTK_LIBD3DSHARED_PATH"')"
set --
eval "$forward"
forwarded=""
for arg in "$@"; do
  case "$arg" in CX_APPLEGPTK_LIBD3DSHARED_PATH=*) forwarded=${arg#*=} ;; esac
done
is "game launcher receives the path as one argument" "$library" "$forwarded"
# macOS sed stops at the first invalid UTF-8 value.
# shellcheck disable=SC2016 # The stub and loop expand inside the child shell.
after_bad=$(env -i PATH="$PATH" LANG=en_US.UTF-8 DXVK_HUD=1 sh -c '
  env() { printf "A_BAD=a\377b\nDXVK_HUD=1\n"; }
  f=$1; set --; eval "$f"; printf "%s " "$@"' sh "$forward")
is "settings after a non-UTF-8 value are forwarded" "--env DXVK_HUD=1 " "$after_bad"

echo "== Rosetta-only settings on arm64 Wine =="
drop=$(sed -n '/^np_dropped=""$/,/^fi$/p' "$SRC")
[ -n "$drop" ] || { echo "FAIL: the arm64 settings block was not found"; exit 1; }
defaults=$(sed -n '/^np_from_defaults() {$/,/^np_dropped=""$/p' "$SRC")
[ -n "$defaults" ] || { echo "FAIL: the defaults block was not found"; exit 1; }
verb=run
eval "$defaults"
drop_at=$(grep -n '^np_dropped=""$' "$SRC" | cut -d: -f1)
# shellcheck disable=SC2016 # Match the literal launcher loop.
forward_at=$(grep -n '^ *for name in $(env .*CX_APPLEGPTK' "$SRC" | cut -d: -f1)
[ "$drop_at" -lt "$forward_at" ] ||
  bad "the arm64 settings block runs before the forwarding loop" "< $forward_at" "$drop_at"
seen() { sh -c 'env | sed -nE "s/^(CX_GRAPHICS_BACKEND|D3DM_[A-Z0-9_]*|DXMT_[A-Z0-9_]*|ROSETTA_[A-Z0-9_]*)=.*/\1/p" | sort | tr "\n" " "'; }
for name in $(seen); do unset -v "$name"; done
CX_ROOT="/R R"
set_all() { export CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1 ROSETTA_ADVERTISE_AVX=0 DXMT_CONFIG=x; }
set_all
wine_unix="/R R/lib/wine/x86_64-unix"
eval "$drop"
is "x86_64 Wine keeps every setting" \
  "CX_GRAPHICS_BACKEND D3DM_ENABLE_METALFX DXMT_CONFIG ROSETTA_ADVERTISE_AVX " "$(seen)"
is "x86_64 Wine logs nothing" "" "$np_dropped"
wine_unix="/R R/lib/wine/aarch64-unix"
eval "$drop"
is "D3DMetal and Rosetta settings leave the environment" "DXMT_CONFIG " "$(seen)"
is "the run log names what was ignored" \
  "CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX ROSETTA_ADVERTISE_AVX" "$np_dropped"
set_all
export CX_GRAPHICS_BACKEND=dxmt
unset -v D3DM_ENABLE_METALFX ROSETTA_ADVERTISE_AVX
eval "$drop"
is "other backends stay" "CX_GRAPHICS_BACKEND DXMT_CONFIG " "$(seen)"
is "nothing to ignore logs nothing" "" "$np_dropped"
unset -v CX_GRAPHICS_BACKEND DXMT_CONFIG

echo "== Rosetta AVX =="
wine_unix="/R R/lib/wine/x86_64-unix"
eval "$drop"
is "x86_64 Wine turns it on" "1" "$ROSETTA_ADVERTISE_AVX"
is "the default is logged as the default" "default" "$avx_from"
is "helpers inherit it" "1" "$(sh -c 'printf %s "$ROSETTA_ADVERTISE_AVX"')"
ROSETTA_ADVERTISE_AVX=0
eval "$drop"
is "a launch option of 0 is kept" "0" "$ROSETTA_ADVERTISE_AVX"
is "a launch option is logged as one" "environment" "$avx_from"
ROSETTA_ADVERTISE_AVX=
eval "$drop"
is "an empty launch option turns it on" "1" "$ROSETTA_ADVERTISE_AVX"
wine_unix="/R R/lib/wine/aarch64-unix"
eval "$drop"
is "arm64 Wine leaves it unset" "unset" "${ROSETTA_ADVERTISE_AVX-unset}"

echo "== FEX reduced x87 precision =="
unset -v FEX_X87REDUCEDPRECISION
wine_unix="/R R/lib/wine/x86_64-unix"
eval "$drop"
is "x86_64 Wine leaves it unset" "unset" "${FEX_X87REDUCEDPRECISION-unset}"
wine_unix="/R R/lib/wine/aarch64-unix"
eval "$drop"
is "arm64 Wine turns it on" "1" "$FEX_X87REDUCEDPRECISION"
is "the default is logged as the default" "default" "$fex_from"
is "helpers inherit it" "1" "$(sh -c 'printf %s "$FEX_X87REDUCEDPRECISION"')"
FEX_X87REDUCEDPRECISION=0
eval "$drop"
is "a launch option of 0 is kept" "0" "$FEX_X87REDUCEDPRECISION"
is "a launch option is logged as one" "environment" "$fex_from"
FEX_X87REDUCEDPRECISION=
eval "$drop"
is "an empty launch option is kept" "" "$FEX_X87REDUCEDPRECISION"
export FEX_X87REDUCEDPRECISION=0 FEX_MULTIBLOCK=0
set --
eval "$forward"
fex_args=""
for arg in "$@"; do
  case "$arg" in FEX_*) fex_args="$fex_args$arg
" ;; esac
done
is "FEX settings reach the game" "FEX_MULTIBLOCK=0 FEX_X87REDUCEDPRECISION=0 " "$(printf %s "$fex_args" | sort | tr '\n' ' ')"
unset -v FEX_X87REDUCEDPRECISION FEX_MULTIBLOCK

echo "== Default Compatibility Settings =="
mkdir -p "$np_support"
cat > "$np_support/defaults-rosetta" <<'EOF'
MTL_HUD_ENABLED=1
WINEMSYNC=1
ROSETTA_ADVERTISE_AVX=0
CX_GRAPHICS_BACKEND=dxmt
DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.5
FEX_X87REDUCEDPRECISION=0
CX_GRAPHICS_BACKEND=vulkan
NOTPROTON_RETINA=yes
DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1;touch x
WINEDEBUG=+all
FOO=$(touch "$work/ran")

EOF
printf 'D3DM_ENABLE_METALFX=1\nCX_GRAPHICS_BACKEND=d3dmetal\nWINEMSYNC=1\nFEX_X87REDUCEDPRECISION=0' \
  > "$np_support/defaults-fex"
keys="MTL_HUD_ENABLED WINEMSYNC ROSETTA_ADVERTISE_AVX CX_GRAPHICS_BACKEND DXMT_CONFIG \
FEX_X87REDUCEDPRECISION NOTPROTON_RETINA D3DM_ENABLE_METALFX WINEDEBUG FOO"
clear() { for k in $keys; do unset -v "$k"; done; }
clear
wine_unix="/R R/lib/wine/x86_64-unix"
verb=waitforexitandrun
eval "$defaults"
is "unset settings take the default" "1 1 0 dxmt" \
  "$MTL_HUD_ENABLED $WINEMSYNC $ROSETTA_ADVERTISE_AVX $CX_GRAPHICS_BACKEND"
is "the default factor is the DXMT_CONFIG" "d3d11.metalSpatialUpscaleFactor=1.5" "${DXMT_CONFIG-}"
is "the game gets them" "1" "$(sh -c 'printf %s "$MTL_HUD_ENABLED"')"
is "lines that are not settings for this runner are skipped" "unset unset unset unset" \
  "${FEX_X87REDUCEDPRECISION-unset} ${NOTPROTON_RETINA-unset} ${WINEDEBUG-unset} ${FOO-unset}"
is "nothing in the file runs" "absent" "$([ -e "$work/ran" ] && echo ran || echo absent)"
is "the run log names what came from the defaults" \
  "MTL_HUD_ENABLED=1 WINEMSYNC=1 ROSETTA_ADVERTISE_AVX=0 CX_GRAPHICS_BACKEND=dxmt DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.5" \
  "$np_defaulted"
is "the run log names the file" "defaults-rosetta" "${np_defaults_file##*/}"
eval "$drop"
is "a defaulted AVX2 is logged as one" "defaults-rosetta" "$avx_from"
is "a defaulted AVX2 keeps its 0" "0" "$ROSETTA_ADVERTISE_AVX"
if np_from_defaults WINEMSYNC; then msync=yes; else msync=no; fi
is "MSync knows it came from the defaults" "yes" "$msync"

clear
export MTL_HUD_ENABLED=0 CX_GRAPHICS_BACKEND=auto DXMT_CONFIG="d3d11.preferredMaxFrameRate=60" ROSETTA_ADVERTISE_AVX=1
eval "$defaults"
is "the game's settings win" "0 1" "$MTL_HUD_ENABLED $ROSETTA_ADVERTISE_AVX"
is "the game's Automatic wins and leaves the backend unset" "unset" "${CX_GRAPHICS_BACKEND-unset}"
is "the default factor joins the game's DXMT_CONFIG" \
  "d3d11.preferredMaxFrameRate=60;d3d11.metalSpatialUpscaleFactor=1.5" "$DXMT_CONFIG"
eval "$drop"
is "a game AVX2 is logged as the game's" "environment" "$avx_from"
if np_from_defaults MTL_HUD_ENABLED; then hud=yes; else hud=no; fi
is "a game setting is not from the defaults" "no" "$hud"
clear
export DXMT_CONFIG="a=1; d3d11.metalSpatialUpscaleFactor = 3.0"
eval "$defaults"
is "the game's factor wins" "a=1; d3d11.metalSpatialUpscaleFactor = 3.0" "$DXMT_CONFIG"
clear
cp "$np_support/defaults-rosetta" "$work/rosetta.keep"
printf 'DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=.\nDXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1234567\nDXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=\n' \
  > "$np_support/defaults-rosetta"
eval "$defaults"
is "factors the Settings page would refuse are skipped" "unset" "${DXMT_CONFIG-unset}"
mv "$work/rosetta.keep" "$np_support/defaults-rosetta"

clear
verb=run
eval "$defaults"
is "helpers get no defaults" "unset" "${MTL_HUD_ENABLED-unset}"

clear
verb=waitforexitandrun
wine_unix="/R R/lib/wine/aarch64-unix"
eval "$defaults"
is "arm64 Wine reads the FEX file" "defaults-fex" "${np_defaults_file##*/}"
is "a last line without a newline is read" "1 0" "$WINEMSYNC $FEX_X87REDUCEDPRECISION"
is "FEX skips the Rosetta-only settings" "unset unset" "${D3DM_ENABLE_METALFX-unset} ${CX_GRAPHICS_BACKEND-unset}"
eval "$drop"
is "a defaulted x87 is logged as one" "defaults-fex" "$fex_from"
clear
rm -f "$np_support/defaults-fex"
eval "$defaults"
is "no file sets nothing" "unset" "${WINEMSYNC-unset}"
printf 'WINEMSYNC=1\n' > "$np_support/defaults-fex"
chmod 000 "$np_support/defaults-fex"
for sh in /bin/sh /bin/dash; do
  [ -x "$sh" ] || continue
  # shellcheck disable=SC2016
  is "an unreadable file is skipped by $sh, the launch goes on" "went on unset" \
    "$(np_support="$np_support" wine_unix="$wine_unix" verb="$verb" np_block="$defaults" \
      "$sh" -c 'set -e; eval "$np_block"; echo "went on ${WINEMSYNC-unset}"' 2>/dev/null)"
done
chmod 644 "$np_support/defaults-fex"
rm -f "$np_support/defaults-fex"

echo "== Per-build defaults =="
printf 'WINEMSYNC=1\nFEX_X87REDUCEDPRECISION=0\n' > "$np_support/defaults-fex"
printf 'MTL_HUD_ENABLED=1\nFEX_X87REDUCEDPRECISION=1\n' > "$np_support/defaults-override-26.1-fex"
printf 'NOTPROTON_RETINA=1\n' > "$np_support/defaults-override-26.1-rosetta"
clear; unset -v MTL_HUD_ENABLED NOTPROTON_RETINA
np_build=26.1 np_flavor=fex
eval "$defaults"
is "a build's own file replaces the runner's" "defaults-override-26.1-fex" "${np_defaults_file##*/}"
is "the build's settings apply, the runner's do not" "1 1 unset" \
  "${MTL_HUD_ENABLED-unset} $FEX_X87REDUCEDPRECISION ${WINEMSYNC-unset}"
clear; unset -v MTL_HUD_ENABLED
np_build=27.0
eval "$defaults"
is "a build without its own file, like a new one, uses the runner's" "defaults-fex 1" \
  "${np_defaults_file##*/} ${WINEMSYNC-unset}"
clear
: > "$np_support/defaults-override-27.0-fex"
eval "$defaults"
is "an empty build file means no defaults for that build" "unset" "${WINEMSYNC-unset}"
rm -f "$np_support/defaults-override-27.0-fex"
clear; unset -v NOTPROTON_RETINA
np_build=26.1 np_flavor=rosetta wine_unix="/R R/lib/wine/x86_64-unix"
eval "$defaults"
is "the same build on Rosetta reads its Rosetta file" "defaults-override-26.1-rosetta 1" \
  "${np_defaults_file##*/} ${NOTPROTON_RETINA-unset}"
clear; unset -v NOTPROTON_RETINA
np_build="" np_flavor=""
eval "$defaults"
is "no build reads the runner's file" "defaults-rosetta" "${np_defaults_file##*/}"
clear
np_build=27.0 np_flavor=fex
eval "$defaults"
is "a FEX tool on x86 Wine still reads the FEX file the page shows" "defaults-fex" "${np_defaults_file##*/}"
is "and still skips what x86 Wine cannot take" "unset" "${FEX_X87REDUCEDPRECISION-unset}"
rm -f "$np_support/defaults-fex" "$np_support/defaults-override-26.1-fex" "$np_support/defaults-override-26.1-rosetta"
unset -v np_build np_flavor
clear; unset -v MTL_HUD_ENABLED NOTPROTON_RETINA
verb=run

echo "== MSync carry-over =="
msync=$(sed -n '/^  msync_from=environment$/,/notproton-msync" 2>\/dev\/null || true$/p' "$SRC")
[ -n "$msync" ] || { echo "FAIL: the MSync block was not found"; exit 1; }
STEAM_COMPAT_DATA_PATH="$work/compat"
mkdir -p "$STEAM_COMPAT_DATA_PATH"
printf 1 > "$STEAM_COMPAT_DATA_PATH/notproton-msync"
np_defaulted="" WINEMSYNC="" verb=waitforexitandrun
eval "$msync"
is "a game without MSync set does not inherit its last launch" "0 default" "$WINEMSYNC $msync_from"
is "and helpers then follow it" "0" "$(cat "$STEAM_COMPAT_DATA_PATH/notproton-msync")"
printf 1 > "$STEAM_COMPAT_DATA_PATH/notproton-msync"
WINEMSYNC="" verb=run
eval "$msync"
is "a helper follows the game's last launch" "1 carried-over" "$WINEMSYNC $msync_from"
unset -v STEAM_COMPAT_DATA_PATH WINEMSYNC
verb=run

if [ "$fails" -eq 0 ]; then
	echo "==> envcheck: all assertions hold"
else
	echo "==> envcheck: $fails failed"
	exit 1
fi
