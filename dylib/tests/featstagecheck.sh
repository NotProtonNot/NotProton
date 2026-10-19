#!/bin/sh
# A descriptor that stages DLLs into the prefix has to put them there and add to
# WINEDLLOVERRIDES without dropping the bridge's own entries.
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "featstagecheck: $SRC not present, skipped"; exit 0; }

block=$(sed -n '/^np_feat_dir=/,/^done$/p' "$SRC")
case "$block" in
  *np_feat_stage*np_feat_over*) ;;
  *) echo "FAIL: the descriptor loop was not found in $SRC"; exit 1 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stage" "$work/pfx/drive_c/windows/system32" \
         "$work/.config/notproton/features.d"
printf 'shipped\n' > "$work/pfx/drive_c/windows/system32/d3d11.dll"
printf 'ours\n'    > "$work/stage/d3d11.dll"
printf 'ours\n'    > "$work/stage/dxgi.dll"
printf '%s\n' "$block" > "$work/block.sh"

cat > "$work/feature.conf" <<EOF
key = NOTPROTON_TESTFEAT
label = Test
section = dev
on = 1
stage = $work/stage
overrides = d3d11,dxgi=n
EOF

run() {
  cp -f "$work/feature.conf" "$work/.config/notproton/features.d/50-test.conf"
  HOME="$work" np_support="$work/support" log=/dev/null np_env_names="" \
    STEAM_DYLD_INSERT_LIBRARIES="" WINEPREFIX="$work/pfx" \
    WINEDLLOVERRIDES="steamclient=n;lsteamclient=b" \
    NOTPROTON_TESTFEAT="$1" \
    sh -c 'export NOTPROTON_TESTFEAT HOME; . "$1/block.sh"; printf "%s" "$WINEDLLOVERRIDES"' \
       sh "$work"
}

fail=0
ok() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else
  echo "  FAIL  $1 (want [$3], got [$2])"; fail=1; fi; }

overrides=$(run 1)
ok "the staged DLL replaces the shipped one" "$(cat "$work/pfx/drive_c/windows/system32/d3d11.dll")" "ours"
ok "every file in the directory is staged" "$(cat "$work/pfx/drive_c/windows/system32/dxgi.dll")" "ours"
ok "the overrides are appended, not assigned" "$overrides" "steamclient=n;lsteamclient=b;d3d11,dxgi=n"

printf 'shipped\n' > "$work/pfx/drive_c/windows/system32/d3d11.dll"
overrides=$(run 0)
ok "a feature switched off stages nothing" "$(cat "$work/pfx/drive_c/windows/system32/d3d11.dll")" "shipped"
ok "and adds no overrides" "$overrides" "steamclient=n;lsteamclient=b"

# A stage directory that is not there is a user error, not a reason to refuse the launch.
sed "s|^stage = .*|stage = $work/missing|" "$work/feature.conf" > "$work/feature.conf.new"
mv -f "$work/feature.conf.new" "$work/feature.conf"
overrides=$(run 1)
ok "a missing stage directory still launches" "$overrides" "steamclient=n;lsteamclient=b;d3d11,dxgi=n"

[ "$fail" -eq 0 ] || exit 1
echo "==> featstagecheck: descriptors stage into the prefix and extend the overrides"
