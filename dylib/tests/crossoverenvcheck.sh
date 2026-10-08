#!/bin/sh
# shellcheck disable=SC2016,SC2034,SC2154 # the grep pattern matches a literal $CX_ROOT
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "crossoverenvcheck: $SRC not present, skipped"; exit 0; }

for fn in crossover_env import_crossover_env; do
	body=$(sed -n "/^$fn() {\$/,/^}\$/p" "$SRC")
	[ -n "$body" ] || { echo "FAIL: $fn not found in $SRC"; exit 1; }
	eval "$body"
done
grep -q '^import_crossover_env "$CX_ROOT/etc/CrossOver.conf"$' "$SRC" \
	|| { echo "FAIL: the run script never imports the runner's CrossOver.conf"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
log="$work/log"

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# What GPTK Patcher leaves in a copy, with the stock sections around it.
cat > "$work/CrossOver.conf" <<'EOF'
[CrossOver]
"BottleDir" = "Bottles"

[EnvironmentVariables] ; added by a patcher
"D3DM_ENABLE_METALFX" = "1"
"DXMT_ENABLE_NVEXT" = "1"
"D3DM_MAX_FPS" = "60"
"MTL_HUD_ENABLED" = "0"
"MTL_HUD_ENABLED" = "1"
"WINEDEBUG" = "+all"
"DXMT_CONFIG" = "$HOME/evil"
"D3DM_QUOTE" = "a\"b"
;"D3DM_COMMENTED" = "1"

[Wine]
"DXMT_IN_WRONG_SECTION" = "1"

[environmentvariables]
"CX_GRAPHICS_BACKEND" = "d3dmetal"
EOF

echo "== parsing =="
want='CX_GRAPHICS_BACKEND=d3dmetal
D3DM_ENABLE_METALFX=1
D3DM_MAX_FPS=60
DXMT_ENABLE_NVEXT=1
MTL_HUD_ENABLED=1'
is "graphics keys only, last assignment wins, every such section" "$want" "$(crossover_env "$work/CrossOver.conf")"
is "a missing file prints nothing" "" "$(crossover_env "$work/absent.conf")"
printf '[EnvironmentVariables]\r\n"D3DM_ENABLE_METALFX" = "1"\r\n' > "$work/crlf.conf"
is "CRLF files read the same" "D3DM_ENABLE_METALFX=1" "$(crossover_env "$work/crlf.conf")"

echo "== importing =="
(
	unset D3DM_ENABLE_METALFX DXMT_ENABLE_NVEXT MTL_HUD_ENABLED CX_GRAPHICS_BACKEND
	D3DM_MAX_FPS=30
	export D3DM_MAX_FPS
	import_crossover_env "$work/CrossOver.conf"
	printf '%s\n' "$D3DM_ENABLE_METALFX $D3DM_MAX_FPS $MTL_HUD_ENABLED $CX_GRAPHICS_BACKEND" > "$work/seen"
	env | grep -q '^DXMT_ENABLE_NVEXT=1$' && echo exported >> "$work/seen"
)
is "launch options keep their value, the rest are exported" "1 30 1 d3dmetal
exported" "$(cat "$work/seen")"
is "what was taken is logged" "4" "$(grep -c '^CrossOver.conf: ' "$log")"
(
	CX_GRAPHICS_BACKEND=""
	import_crossover_env "$work/CrossOver.conf"
	printf '[%s]\n' "$CX_GRAPHICS_BACKEND" > "$work/empty"
)
is "a key set to empty on purpose stays empty" "[]" "$(cat "$work/empty")"

if [ "$fails" -eq 0 ]; then
	echo "==> crossoverenvcheck: all assertions hold"
else
	echo "==> crossoverenvcheck: $fails failed"
	exit 1
fi
