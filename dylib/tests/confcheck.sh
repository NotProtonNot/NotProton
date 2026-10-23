#!/bin/sh
# The run script's descriptor reader, against the corpus in conf-fixtures. The same
# corpus judges webpatch.c's reader through confdump, so the two cannot drift: what
# the panel offers and what a launch does come from one grammar.
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
FIX="${2:-$(dirname "$0")/conf-fixtures}"
[ -f "$SRC" ] || { echo "confcheck: $SRC not present, skipped"; exit 0; }
[ -d "$FIX" ] || { echo "confcheck: $FIX not present, skipped"; exit 0; }

# Taken from the shipped script rather than copied, so this checks what actually runs.
fn=$(sed -n '/^np_conf_normalise() (/,/^)$/p' "$SRC")
[ -n "$fn" ] || { echo "FAIL: np_conf_normalise not found in $SRC"; exit 1; }
eval "$fn"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
{
  np_conf_normalise "$FIX/plugins" plugins plugin
  np_conf_normalise "$FIX/variants" variants variant
} > "$work/got"
grep -v '^#' "$FIX/EXPECTED" | grep -v '^$' > "$work/want"

if diff -u "$work/want" "$work/got" > "$work/diff"; then
  echo "==> confcheck: $(grep -c . "$work/got") normalised lines match EXPECTED"
else
  echo "FAIL: the run script does not read the corpus as EXPECTED says"
  head -40 "$work/diff"
  exit 1
fi
