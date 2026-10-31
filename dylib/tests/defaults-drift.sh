#!/bin/sh
set -eu

root=$(cd -- "$(dirname "$0")/.." && pwd)
compat_run="$root/feats/compat_run.sh"
webpatch="$root/feats/webpatch.c"
settings=$("$1" --settings)

fail=0
no() { printf 'FAIL: %s\n' "$1"; fail=1; }
words() { tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '; }
same() { [ -n "$2" ] || no "$1: nothing found in defaults.c"
    [ "$(printf '%s' "$2" | words)" = "$(printf '%s' "$3" | words)" ] \
    || no "$1: [$(printf '%s' "$2" | words)] vs [$(printf '%s' "$3" | words)]"; }
field() { printf '%s\n' "$settings" | awk -v kind="$1" -v key="$2" \
    '$1 == kind && $2 == key { for (i = 3; i <= NF; i++) print $i }'; }

all=$(printf '%s\n' "$settings" | awk '$1 == "key" { print $2 }')
rosetta_only=$(printf '%s\n' "$settings" | awk '$1 == "key" && $3 == "rosetta" && NF == 3 { print $2 }')
fex_only=$(printf '%s\n' "$settings" | awk '$1 == "key" && $3 == "fex" && NF == 3 { print $2 }')
[ -n "$all" ] || no "defaults-check printed no settings"

# shellcheck disable=SC2016 # Match the literal case line.
arms=$(sed -n '/^np_from_defaults() {$/,/^np_dropped=""$/p' "$compat_run" \
  | sed -n '/case "\$line" in/,/^[[:space:]]*esac$/p')
[ -n "$arms" ] || no "no case arms found in the defaults block of compat_run.sh"
sh_rosetta=$(printf '%s\n' "$arms" | grep -B1 '" != aarch64-unix ] || continue' | grep ')$' || true)
sh_fex=$(printf '%s\n' "$arms" | grep -B1 '" = aarch64-unix ] || continue' | grep ')$' || true)

panel_src=$(sed -n '/^#define NP_CX_PANEL(RT, BARREL)/,/^$/p' "$webpatch")
panel=$(printf '%s\n' "$panel_src" | grep -oE '[(\[]\\"[A-Z][A-Z0-9_]*\\"' \
  | sed 's/^.\\"//; s/\\"$//' | sort -u)
[ -n "$panel" ] || no "no setting keys found in NP_CX_PANEL"
for key in $panel; do
    # Neither of these is a setting with a default: variants are a game's own choice,
    # and the insert list is how a tool without our run script carries a plugin.
    case "$key" in NOTPROTON_RUNNER_VARIANT|DYLD_INSERT_LIBRARIES) continue ;; esac
    printf '%s\n' "$all" | grep -Fxq "$key" || no "$key is on the panel but not in g_settings"
done
for key in $all; do
    printf '%s\n' "$panel" | grep -Fxq "$key" || no "$key is in g_settings but not on the panel"
    printf '%s' "$arms" | grep -Fq "$key=" || no "$key has no case arm in the defaults block"
    if [ "$(field values "$key" | words)" = "0 1 " ]; then
        printf '%s' "$arms" | grep -Fq "$key=[01]" || no "$key does not take 0 and 1 in compat_run.sh"
    fi
done
for key in $rosetta_only; do
    printf '%s' "$sh_rosetta" | grep -Fq "$key=" || no "$key is not Rosetta-only in compat_run.sh"
done
for key in $fex_only; do
    printf '%s' "$sh_fex" | grep -Fq "$key=" || no "$key is not FEX-only in compat_run.sh"
done

shared=$(printf '%s\n' "$settings" | awk '$1 == "key" && NF == 4 { print $2 }')
for key in $shared; do
    [ -z "$(field rosetta-values "$key")" ] || continue
    if printf '%s%s' "$sh_rosetta" "$sh_fex" | grep -Fq "$key="; then
        no "$key is for both runners in defaults.c but compat_run.sh limits it to one"
    fi
done

sh_backends=$(printf '%s\n' "$arms" | grep -oE 'CX_GRAPHICS_BACKEND=[a-z0-9]+' | sed 's/.*=//')
sh_rosetta_backends=$(printf '%s\n' "$sh_rosetta" | grep -oE 'CX_GRAPHICS_BACKEND=[a-z0-9]+' | sed 's/.*=//')
# shellcheck disable=SC2016 # Match the literal case line.
sh_factors=$(printf '%s\n' "$arms" | grep -F 'case "${value#*=}" in' \
  | sed 's/.* in \(.*\)) ;;.*/\1/' | tr -d '|')
panel_list() { printf '%s\n' "$panel_src" | tr -d '\n' | grep -oE "$1=\[[^]]*\]" \
  | grep -oE 'data:\\"[a-z0-9.]+\\"' | sed 's/data:\\"//; s/\\"//'; }
panel_rosetta_backends=$(printf '%s\n' "$panel_src" | grep -oE 'x\.data!==\\"[a-z0-9]+\\"' \
  | sed 's/.*!==\\"//; s/\\"//')

c_backends="$(field values CX_GRAPHICS_BACKEND) $(field rosetta-values CX_GRAPHICS_BACKEND)"
c_rosetta_backends=$(field rosetta-values CX_GRAPHICS_BACKEND)
c_factors=$(field values DXMT_CONFIG)
same "backends in defaults.c and compat_run.sh" "$c_backends" "$sh_backends"
same "backends in defaults.c and the panel" "$c_backends" "$(panel_list B)"
same "Rosetta-only backends in defaults.c and compat_run.sh" "$c_rosetta_backends" "$sh_rosetta_backends"
same "Rosetta-only backends in defaults.c and the panel" "$c_rosetta_backends" "$panel_rosetta_backends"
same "upscale factors in defaults.c and compat_run.sh" "$c_factors" "$sh_factors"
same "upscale factors in defaults.c and the panel" "$c_factors" "$(panel_list U)"

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "==> defaults-drift: setting lists and their values agree"
