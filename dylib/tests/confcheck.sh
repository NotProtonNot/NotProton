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

lookups=$(awk '/^np_conf_value\(\) \{/ { on = 1 } on { print } on && /^np_conf_has\(\) \{/ { last = 1 } last && /^\}/ { exit }' "$SRC")
eval "$lookups"
table=$(printf '2.1\tsrc\told\n2.10\tsrc\tnew\n10\tsrc\tten\n')
if [ "$(np_conf_value "$table" 2.10 src)" != new ] || [ -n "$(np_conf_values "$table" 010 src)" ] \
  || np_conf_has "$table" 1e1; then
  echo "FAIL: numeric-looking ids match each other"; exit 1
fi

if diff -u "$work/want" "$work/got" > "$work/diff"; then
  echo "==> confcheck: $(grep -c . "$work/got") normalised lines match EXPECTED"
else
  echo "FAIL: the run script does not read the corpus as EXPECTED says"
  head -40 "$work/diff"
  exit 1
fi
