#!/bin/sh
# NOTPROTON_RUNNER_VARIANT picks a runner assembled from variant descriptors, builds it
# when the trees behind it have moved on, refuses a tree that would silently fail, and
# never stops a game starting.
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "runnervariantcheck: $SRC not present, skipped"; exit 0; }

block=$(sed -n '/^np_variant_conf_dir=/,/^export CX_ROOT$/p' "$SRC")
case "$block" in
  *np_variant_overlay*np_variant_resolve*) ;;
  *) echo "FAIL: the variant block was not found in $SRC"; exit 1 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
base="$work/runners/crossover-26.3/CrossOver"
mkdir -p "$base/lib/wine" "$base/lib/dxmt/x86_64-windows" "$base/lib/dxmt/x86_64-unix" \
         "$work/variants"
printf '%s\n' "$block" > "$work/block.sh"

# A PE winebuild has marked as a builtin carries the marker over the DOS stub at 0x40.
dll() {
  : > "$1"
  dd if=/dev/zero of="$1" bs=1 count=64 2>/dev/null
  printf 'Wine builtin DLL' >> "$1"
  printf '%s' "${2:-}" >> "$1"
}
native_dll() {
  dd if=/dev/zero of="$1" bs=1 count=80 2>/dev/null
}

desc() {
  cat > "$work/variants/$1.conf"
}

resolve() {
  NOTPROTON_RUNNER_VARIANT="$1" NOTPROTON_VARIANT_REBUILD="${2:-}" \
    HOME="$work" np_support="$work" np_build="26.3" np_flavor="${3:-rosetta}" \
    log="$work/log" PATH="$PATH" \
    sh -c '. "$1/block.sh"; printf "%s" "$CX_ROOT"' sh "$work"
}

fail=0
ok() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else
  echo "  FAIL  $1 (want [$3], got [$2])"; fail=1; fi; }
logged() {
  if grep -qF "$2" "$work/log"; then echo "  ok    $1"; else
    echo "  FAIL  $1 (no [$2] in the log)"; fail=1; fi
}

echo "== without descriptors"
ok "no variant uses the build's own runner" "$(resolve '')" "$base"
ok "a variant that is not installed falls back" "$(resolve 'notinstalled')" "$base"
ok "a name with a slash is refused" "$(resolve '../../etc')" "$base"
ok "a name with a space is refused" "$(resolve 'bad name')" "$base"

# What install-dxmt.sh produced before descriptors existed still resolves.
prebuilt="$work/runners/crossover-26.3-prebuilt/CrossOver"
mkdir -p "$prebuilt/lib/wine"
ok "a runner built by hand is still used" "$(resolve 'prebuilt')" "$prebuilt"

echo "== a descriptor builds the runner"
mkdir -p "$work/trees/one/x86_64-windows" "$work/trees/one/x86_64-unix"
dll "$work/trees/one/x86_64-windows/d3d11.dll" one
printf 'unix half\n' > "$work/trees/one/x86_64-unix/winemetal.so"
desc one <<CONF
label   = One
variant = Backend
src     = trees/one
dst     = lib/dxmt
CONF
built="$work/runners/crossover-26.3-one/CrossOver"
ok "the variant runner is used" "$(resolve 'one')" "$built"
ok "the tree is copied in" "$(cat "$built/lib/dxmt/x86_64-windows/d3d11.dll" | tr -d '\000')" \
  "Wine builtin DLLone"
ok "every arch directory is copied" "$(cat "$built/lib/dxmt/x86_64-unix/winemetal.so")" "unix half"
ok "the base runner is left alone" "$(ls "$base/lib/dxmt/x86_64-windows")" ""
ok "a manifest is recorded" \
  "$(sed -n 1p "$built/.notproton-variant")" "one lib/dxmt"

echo "== an unchanged tree is not rebuilt"
: > "$work/log"
marker="$built/lib/wine/not-from-the-tree"
: > "$marker"
ok "the runner is reused" "$(resolve 'one')" "$built"
ok "nothing was rebuilt" "$([ -f "$marker" ] && echo kept)" "kept"

echo "== a changed tree is rebuilt"
dll "$work/trees/one/x86_64-windows/d3d11.dll" twotwotwo
ok "the runner is used" "$(resolve 'one')" "$built"
ok "the new tree is copied in" "$(cat "$built/lib/dxmt/x86_64-windows/d3d11.dll" | tr -d '\000')" \
  "Wine builtin DLLtwotwotwo"
ok "the rebuild is a fresh clone" "$([ -f "$marker" ] || echo gone)" "gone"
logged "the build is reported" "building crossover-26.3-one"

echo "== a rebuild can be forced"
: > "$marker"
ok "the runner is used" "$(resolve 'one' 1)" "$built"
ok "the runner was rebuilt anyway" "$([ -f "$marker" ] || echo gone)" "gone"

echo "== trees that would fail silently are refused"
: > "$work/log"
mkdir -p "$work/trees/native/x86_64-windows"
native_dll "$work/trees/native/x86_64-windows/d3d11.dll"
desc unmarked <<CONF
src = trees/native
dst = lib/dxmt
CONF
ok "a DLL that is not builtin-marked falls back" "$(resolve 'unmarked')" "$base"
logged "and says why" "is not marked as a Wine builtin"

: > "$work/log"
mkdir -p "$work/trees/arm/aarch64-windows"
dll "$work/trees/arm/aarch64-windows/d3d11.dll"
desc otherarch <<CONF
src = trees/arm
dst = lib/dxmt
CONF
ok "a tree for the other architecture falls back" "$(resolve 'otherarch')" "$base"
logged "and says so" "otherarch has nothing for x86_64"

: > "$work/log"
desc typo <<CONF
src  = trees/one
dst  = lib/dxmt
srcc = trees/elsewhere
CONF
ok "an unknown key falls back" "$(resolve 'typo')" "$base"
logged "and names the key" "unknown keys (srcc )"

: > "$work/log"
desc escape <<CONF
src = trees/one
dst = ../../../etc
CONF
ok "a dst that leaves the runner falls back" "$(resolve 'escape')" "$base"
logged "and says why" "dst must be a relative path inside the runner"

: > "$work/log"
desc gone <<CONF
src = trees/not-there
dst = lib/dxmt
CONF
ok "a tree that is not there falls back" "$(resolve 'gone')" "$base"
logged "and says where it looked" "which is not there"

: > "$work/log"
mkdir -p "$work/trees/both/x86_64-windows" "$work/trees/both/aarch64-windows"
dll "$work/trees/both/x86_64-windows/d3d11.dll" bothbothboth
dll "$work/trees/both/aarch64-windows/d3d11.dll" armarmarm
desc bothslots <<CONF
src = trees/both
dst = lib/dxmt
CONF
bothruns="$work/runners/crossover-26.3-bothslots/CrossOver"
ok "a tree carrying both architectures is used" "$(resolve 'bothslots')" "$bothruns"
ok "the slot this runner has is laid down" \
  "$(tr -d '\000' < "$bothruns/lib/dxmt/x86_64-windows/d3d11.dll")" "Wine builtin DLLbothbothboth"
ok "the slot it does not have is left out" \
  "$([ -e "$bothruns/lib/dxmt/aarch64-windows" ] || echo absent)" "absent"
logged "and the skip is reported" "aarch64-windows has no counterpart in this runner"

echo "== a runner holding both slots takes only the one it runs"
# A FEX runner ships an x86_64 slot as well as its own, so a tree landing somewhere is not
# the same as a tree Wine will read. np_compat_tool_builds applies the same rule in the
# panel; if these two disagree, one offers a variant the other refuses.
: > "$work/log"
mkdir -p "$base/lib/dxmt/aarch64-windows"
ok "an x86_64 tree is still used where x86_64 is what runs" "$(resolve 'one' '' rosetta)" "$built"
ok "and is refused where arm64 Wine runs" "$(resolve 'one' '' fex)" "$base"
logged "which says what the runner runs" "has nothing for aarch64, which is what this runner runs"
ok "a tree carrying both is used either way" "$(resolve 'bothslots' 1 fex)" "$bothruns"
ok "and the slot that runner runs is laid down once the runner has it" \
  "$(tr -d '\000' < "$bothruns/lib/dxmt/aarch64-windows/d3d11.dll")" "Wine builtin DLLarmarmarm"
# The check has to run on every launch, not only when the variant is built: a variant
# directory is named for the build, and two tools can share a build with different
# flavors, so the second one asks for a runner that is already there.
: > "$work/log"
ok "an already built variant is re-checked, not waved through" "$(resolve 'one' '' fex)" "$base"
logged "and says so again" "has nothing for aarch64"
# A tree naming no architecture is not filtered: dst may be a flat directory.
: > "$work/log"
mkdir -p "$work/trees/flat"
dll "$work/trees/flat/plain.dll" flat
desc flat <<CONF
src = trees/flat
dst = lib/dxmt
CONF
ok "a tree naming no architecture is left alone" \
  "$(resolve 'flat' '' fex)" "$work/runners/crossover-26.3-flat/CrossOver"

# A tree naming no architecture skips the arch check, so the build-time "nothing landed"
# refusal is what catches one the runner has no directory for.
: > "$work/log"
mkdir -p "$work/trees/nowhere/sub"
dll "$work/trees/nowhere/sub/plain.dll" nowhere
desc nowhere <<CONF
src = trees/nowhere
dst = lib/dxmt
CONF
ok "a tree the runner has no directory for falls back" "$(resolve 'nowhere')" "$base"
logged "and says nothing landed" "nothing in nowhere belongs in this runner"

echo "== combinations"
mkdir -p "$work/trees/other/x86_64-windows"
dll "$work/trees/other/x86_64-windows/dxgi.dll" other
desc other <<CONF
src = trees/other
dst = lib/dxmt
CONF
both="$work/runners/crossover-26.3-one-other/CrossOver"
ok "two variants build one runner" "$(resolve 'one+other')" "$both"
ok "the first tree is in it" "$(cat "$both/lib/dxmt/x86_64-windows/d3d11.dll" | tr -d '\000')" \
  "Wine builtin DLLtwotwotwo"
ok "the second tree is in it" "$(cat "$both/lib/dxmt/x86_64-windows/dxgi.dll" | tr -d '\000')" \
  "Wine builtin DLLother"
ok "the order asked for does not matter" "$(resolve 'other+one')" "$both"
ok "a repeated name does not repeat in the name" "$(resolve 'one+one')" "$built"

echo "== a request naming something unusable"
: > "$work/log"
ok "the members that work are still used" "$(resolve 'one+gone')" "$built"
logged "and the rest is reported" "ignoring gone, which cannot be used"
ok "a request of nothing but unusable names falls back" "$(resolve 'gone+typo')" "$base"
# The runner is named for what went into it, not for what was asked for.
ok "the runner is named for the members that worked" \
  "$([ -d "$work/runners/crossover-26.3-one-gone" ] || echo absent)" "absent"
# And a prebuilt runner is still reachable when nothing in the request has a descriptor.
ok "a prebuilt runner still resolves beside descriptors" "$(resolve 'prebuilt')" "$prebuilt"

echo "== a live runner is left alone"
: > "$work/log"
: > "$marker"
dll "$work/trees/one/x86_64-windows/d3d11.dll" threethreethree
# np_variant_busy reads the executable path of every process, as RunnerInstaller.isRunning
# does. Standing a fake ps in for one keeps the test off whether macOS will run a copied
# binary; the assumption it rests on -- that ps prints absolute paths -- is checked below.
mkdir -p "$work/fakebin"
cat > "$work/fakebin/ps" <<FAKE
#!/bin/sh
printf '%s\n' /usr/libexec/somethingelse "$built/lib/wine/x86_64-unix/wine"
FAKE
chmod +x "$work/fakebin/ps"
ok "the runner is still used" "$(PATH="$work/fakebin:$PATH" resolve 'one')" "$built"
ok "and is not rebuilt under the running game" "$([ -f "$marker" ] && echo kept)" "kept"
logged "and says why" "leaving it as it is"

# shellcheck disable=SC2009 # the point is the shape of what ps prints
ok "ps really does print absolute executable paths" \
  "$(ps -axww -o comm= | sed -n 's|^\(/[^ ]*\)/[^/ ]*$|yes|p' | head -1)" "yes"

[ "$fail" -eq 0 ] || exit 1
echo "==> runnervariantcheck: variants build on demand, refuse bad trees and fall back"
