#!/bin/sh
# NOTPROTON_RUNNER_VARIANT picks a runner assembled from variant descriptors, builds it
# when the trees behind it have moved on, refuses a tree that would silently fail, and
# never stops a game starting.
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "runnervariantcheck: $SRC not present, skipped"; exit 0; }

# The reader comes along: the variant block reads descriptors through it now.
block=$(sed -n '/^np_conf_normalise() (/,/^export CX_ROOT$/p' "$SRC")
case "$block" in
  *np_conf_normalise*np_variant_overlay*np_variant_resolve*) ;;
  *) echo "FAIL: the variant block was not found in $SRC"; exit 1 ;;
esac
switch_fn=$(sed -n '/^note_variant_switch() {/,/^}/p' "$SRC")
[ -n "$switch_fn" ] || { echo "FAIL: note_variant_switch was not found in $SRC"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
base="$work/runners/crossover-26.3/CrossOver"
mkdir -p "$base/lib/wine/x86_64-windows" "$base/lib/wine/x86_64-unix" "$base/bin" \
         "$base/lib/dxmt/x86_64-windows" "$base/lib/dxmt/x86_64-unix" "$work/variants"
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
  { printf '[%s]\n' "$1"; cat; } > "$work/variants/$1.conf"
}

resolve() {
  NOTPROTON_RUNNER_VARIANT="$1" NOTPROTON_VARIANT_REBUILD="${2:-}" \
    HOME="$work" np_support="$work" np_build="26.3" np_flavor="${3:-rosetta}" \
    log="$work/log" PATH="$PATH" \
    sh -c '. "$1/block.sh"; printf "%s" "$CX_ROOT"' sh "$work"
}

# Each build is named crossover-<build>+<names>@<hash>, so the newest one is the current one.
# shellcheck disable=SC2012 # names made by the block, sorted by time
newest() {
  d=$(ls -dt "$work/runners/crossover-26.3+$1"@* 2>/dev/null | head -1)
  [ -n "$d" ] && printf '%s/CrossOver' "$d"
}
builds_of() {
  n=0
  for d in "$work/runners/crossover-26.3+$1"@*; do [ ! -d "$d" ] || n=$((n + 1)); done
  printf '%s' "$n"
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
got=$(resolve 'one')
built=$(newest one)
case "$got" in
  "$work/runners/crossover-26.3+one@"????????????/CrossOver) echo "  ok    the variant runner is used, named for its contents" ;;
  *) echo "  FAIL  the variant runner is used, named for its contents (got [$got])"; fail=1 ;;
esac
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
old=$built
got=$(resolve 'one')
built=$(newest one)
ok "the new build is used" "$got" "$built"
ok "and is not the old one" "$([ "$built" != "$old" ] && echo new)" "new"
ok "the new tree is copied in" "$(cat "$built/lib/dxmt/x86_64-windows/d3d11.dll" | tr -d '\000')" \
  "Wine builtin DLLtwotwotwo"
ok "the rebuild is a fresh clone" "$([ -f "$built/lib/wine/not-from-the-tree" ] || echo gone)" "gone"
logged "the build is reported" "building crossover-26.3+one@"
ok "the old build is kept for a while, since a launch may have just resolved it" "$(builds_of one)" "2"
touch -t 202001010000 "${old%/CrossOver}/.notproton-used"
resolve 'one' > /dev/null
ok "and goes once it has sat unused" "$(builds_of one)" "1"
logged "which is reported" "which nothing uses any more"

echo "== a re-patched base runner rebuilds the variant"
old=$built
dll "$base/lib/wine/x86_64-windows/ntdll.dll" patched
ok "the runner is used" "$(resolve 'one')" "$(newest one)"
built=$(newest one)
ok "the variant was rebuilt from the updated base" "$([ "$built" != "$old" ] && echo rebuilt)" "rebuilt"
ok "the updated base ntdll is in the variant" \
  "$(tr -d '\000' < "$built/lib/wine/x86_64-windows/ntdll.dll")" "Wine builtin DLLpatched"

echo "== a rebuild can be forced"
marker="$built/lib/wine/not-from-the-tree"
: > "$marker"
ok "the runner is used" "$(resolve 'one' 1)" "$built"
ok "the runner was rebuilt anyway" "$([ -f "$marker" ] || echo gone)" "gone"

echo "== trees that would fail silently are refused"
: > "$work/log"
mkdir -p "$work/trees/native/x86_64-windows"
native_dll "$work/trees/native/x86_64-windows/d3d11.dll"
desc unmarked <<CONF
label = Unmarked
variant = Backend
src = trees/native
dst = lib/dxmt
CONF
ok "a DLL that is not builtin-marked falls back" "$(resolve 'unmarked')" "$base"
logged "and says why" "is not marked as a Wine builtin"

: > "$work/log"
mkdir -p "$work/trees/arm/aarch64-windows"
dll "$work/trees/arm/aarch64-windows/d3d11.dll"
desc otherarch <<CONF
label = Otherarch
variant = Backend
src = trees/arm
dst = lib/dxmt
CONF
ok "a tree for the other architecture falls back" "$(resolve 'otherarch')" "$base"
logged "and says so" "otherarch has nothing for x86_64"

: > "$work/log"
desc typo <<CONF
label = Typo
variant = Backend
src  = trees/one
dst  = lib/dxmt
srcc = trees/elsewhere
CONF
ok "an unknown key falls back" "$(resolve 'typo')" "$base"
logged "and names the field" "typo refused, unknown-field:srcc"

: > "$work/log"
desc escape <<CONF
label = Escape
variant = Backend
src = trees/one
dst = ../../../etc
CONF
ok "a dst that leaves the runner falls back" "$(resolve 'escape')" "$base"
logged "and says why" "escape refused, bad-value:dst"

: > "$work/log"
desc gone <<CONF
label = Gone
variant = Backend
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
label = Bothslots
variant = Backend
src = trees/both
dst = lib/dxmt
CONF
bothruns=$(resolve 'bothslots')
ok "a tree carrying both architectures is used" "$bothruns" "$(newest bothslots)"
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
ok "an x86_64 tree is still used where x86_64 is what runs" "$(resolve 'one' '' rosetta)" "$(newest one)"
ok "and is refused where arm64 Wine runs" "$(resolve 'one' '' fex)" "$base"
logged "which says what the runner runs" "has nothing for aarch64 that lands in this runner"
bothruns=$(resolve 'bothslots' 1 fex)
ok "a tree carrying both is used either way" "$bothruns" "$(newest bothslots)"
ok "and the slot that runner runs is laid down once the runner has it" \
  "$(tr -d '\000' < "$bothruns/lib/dxmt/aarch64-windows/d3d11.dll")" "Wine builtin DLLarmarmarm"
# The check has to run on every launch, not only when the variant is built: a variant
# directory is named for the build, and two tools can share a build with different
# flavors, so the second one asks for a runner that is already there.
: > "$work/log"
ok "an already built variant is re-checked, not waved through" "$(resolve 'one' '' fex)" "$base"
logged "and says so again" "has nothing for aarch64"
# Hidden files and empty arch directories are ignored.
: > "$work/log"
mkdir -p "$work/trees/one/aarch64-windows"
printf 'junk\n' > "$work/trees/one/aarch64-windows/.DS_Store"
ok "an arch folder holding only .DS_Store does not satisfy that arch" \
  "$(resolve 'one' '' fex)" "$base"
rmdir "$work/trees/one/aarch64-windows" 2>/dev/null || rm -rf "$work/trees/one/aarch64-windows"
# A tree naming no architecture is not filtered: dst may be a flat directory.
: > "$work/log"
mkdir -p "$work/trees/flat"
dll "$work/trees/flat/plain.dll" flat
desc flat <<CONF
label = Flat
variant = Backend
src = trees/flat
dst = lib/dxmt
CONF
got=$(resolve 'flat' '' fex)
ok "a tree naming no architecture is left alone" "$got" "$(newest flat)"

# A tree naming no architecture skips the arch check, but still has to land somewhere.
: > "$work/log"
mkdir -p "$work/trees/nowhere/sub"
dll "$work/trees/nowhere/sub/plain.dll" nowhere
desc nowhere <<CONF
label = Nowhere
variant = Backend
src = trees/nowhere
dst = lib/dxmt
CONF
ok "a tree the runner has no directory for falls back" "$(resolve 'nowhere')" "$base"
logged "and says nothing landed" "nowhere has nothing for x86_64 that lands in this runner"

echo "== replacing wine's own files needs a build"
: > "$work/log"
mkdir -p "$work/trees/winefix/x86_64-windows" "$work/trees/winefix/x86_64-unix"
dll "$work/trees/winefix/x86_64-windows/newthing.dll" new
printf 'unix half\n' > "$work/trees/winefix/x86_64-unix/newthing.so"
desc winefix <<CONF
src = trees/winefix
dst = lib/wine
CONF
got=$(resolve 'winefix')
ok "adding files to lib/wine needs no build" "$got" "$(newest winefix)"
dll "$work/trees/winefix/x86_64-windows/win32u.dll" fixed
ok "nor does a file this runner does not ship" "$(resolve 'winefix')" "$(newest winefix)"
dll "$base/lib/wine/x86_64-windows/win32u.dll" stock
: > "$work/log"
ok "replacing one this runner ships without a build falls back" "$(resolve 'winefix')" "$base"
logged "and names the file" "winefix replaces lib/wine/x86_64-windows/win32u.dll, which is Wine's own"
logged "and gives the line to add" "build = 26.3"
desc winefix <<CONF
src   = trees/winefix
dst   = lib/wine
build = 27.0
build = 26.3
CONF
got=$(resolve 'winefix')
ok "naming this build among others is used" "$got" "$(newest winefix)"
ok "and the fix is in it" "$(tr -d '\000' < "$got/lib/wine/x86_64-windows/win32u.dll")" "Wine builtin DLLfixed"
: > "$work/log"
desc winefix <<CONF
src   = trees/winefix
dst   = lib/wine
build = 27.0
CONF
ok "naming another build falls back" "$(resolve 'winefix')" "$base"
logged "and says what it was for" "winefix is for 27.0 and this runner is 26.3"
# The same file reached from dst "." and in another case is still Wine's.
: > "$work/log"
mkdir -p "$work/trees/dotdst/lib/wine/x86_64-windows"
dll "$work/trees/dotdst/lib/wine/x86_64-windows/WIN32U.DLL" dot
desc dotdst <<CONF
src = trees/dotdst
dst = .
CONF
ok "a tree laid over the whole runner is judged by its files" "$(resolve 'dotdst')" "$base"
logged "and names the file" "dotdst replaces lib/wine/x86_64-windows/WIN32U.DLL"
# Replacing DXMT's files is not Wine.
dll "$base/lib/dxmt/x86_64-windows/dxgi.dll" stock
mkdir -p "$work/trees/viaparent/dxmt/x86_64-windows"
dll "$work/trees/viaparent/dxmt/x86_64-windows/dxgi.dll" parent
desc viaparent <<CONF
src = trees/viaparent
dst = lib
CONF
got=$(resolve 'viaparent')
ok "replacing a DXMT file needs no build" "$got" "$(newest viaparent)"
rm -f "$base/lib/dxmt/x86_64-windows/dxgi.dll"

echo "== the steam bridge is not a variant's to change"
for f in x86_64-windows/ntdll.dll x86_64-unix/ntdll.so x86_64-windows/lsteamclient.dll x86_64-unix/lsteamclient.so; do
  : > "$work/log"
  rm -rf "$work/trees/bridge"
  mkdir -p "$work/trees/bridge/x86_64-windows" "$work/trees/bridge/x86_64-unix"
  dll "$work/trees/bridge/x86_64-windows/win32u.dll" ok
  dll "$work/trees/bridge/$f" bad
  desc bridge <<CONF
src   = trees/bridge
dst   = lib/wine
build = 26.3
CONF
  ok "a tree carrying $f falls back" "$(resolve 'bridge')" "$base"
  logged "and names it" "would change lib/wine/$f, which carries NotProton's Steam bridge"
done
: > "$work/log"
rm -rf "$work/trees/bridge"
mkdir -p "$work/trees/bridge/x86_64-windows"
dll "$work/trees/bridge/x86_64-windows/win32u.dll" ok
desc bridge <<CONF
src    = trees/bridge
dst    = lib/wine
build  = 26.3
remove = ./x86_64-windows//ntdll.dll
CONF
ok "removing ntdll however it is spelled falls back" "$(resolve 'bridge')" "$base"
logged "and names it" "would change lib/wine/x86_64-windows/ntdll.dll"
: > "$work/log"
desc bridge <<CONF
src    = trees/bridge
dst    = Lib/Wine
build  = 26.3
remove = X86_64-Windows/NTDLL.DLL
CONF
ok "or in another case, which APFS takes for the same file" "$(resolve 'bridge')" "$base"
logged "and names it" "would change lib/wine/x86_64-windows/ntdll.dll"

echo "== links in a tree are not followed"
: > "$work/log"
mkdir -p "$work/elsewhere/x86_64-windows"
dll "$work/elsewhere/x86_64-windows/d3d11.dll" linked
mkdir -p "$work/trees/linked"
ln -s "$work/elsewhere/x86_64-windows" "$work/trees/linked/x86_64-windows"
desc linked <<CONF
src = trees/linked
dst = lib/dxmt
CONF
ok "a linked folder lands nothing, as the panel sees it" "$(resolve 'linked')" "$base"
logged "and says so" "linked has nothing for x86_64 that lands in this runner"

echo "== removes"
: > "$work/log"
dll "$base/lib/dxmt/x86_64-windows/nvapi64.dll" stock
mkdir -p "$base/lib/dxmt/x86_64-windows/afolder"
mkdir -p "$work/trees/trim/x86_64-windows"
dll "$work/trees/trim/x86_64-windows/d3d11.dll" trim
desc trim <<CONF
src    = trees/trim
dst    = lib/dxmt
remove = x86_64-windows/nvapi64.dll
remove = x86_64-windows/afolder
remove = x86_64-windows/never-there.dll
CONF
got=$(resolve 'trim')
ok "a variant with removes is used" "$got" "$(newest trim)"
ok "the file is gone from it" "$([ -e "$got/lib/dxmt/x86_64-windows/nvapi64.dll" ] || echo gone)" "gone"
ok "and still in the base runner" "$([ -f "$base/lib/dxmt/x86_64-windows/nvapi64.dll" ] && echo kept)" "kept"
ok "a folder is not removed" "$([ -d "$got/lib/dxmt/x86_64-windows/afolder" ] && echo kept)" "kept"
logged "and says so" "afolder is a folder, and only files are removed"
logged "a remove of nothing is reported" "never-there.dll is not in this runner"
mkdir -p "$work/trees/emptytree"
desc onlyremove <<CONF
src    = trees/emptytree
dst    = lib/dxmt
remove = x86_64-windows/nvapi64.dll
CONF
got=$(resolve 'onlyremove')
ok "a variant that only removes is used" "$got" "$(newest onlyremove)"
ok "and removes" "$([ -e "$got/lib/dxmt/x86_64-windows/nvapi64.dll" ] || echo gone)" "gone"
old=$(newest onlyremove)
dll "$base/lib/dxmt/x86_64-windows/nvngx.dll" stock
desc onlyremove <<CONF
src    = trees/emptytree
dst    = lib/dxmt
remove = x86_64-windows/nvngx.dll
CONF
ok "changing a remove rebuilds" "$(resolve 'onlyremove')" "$(newest onlyremove)"
ok "into a new runner" "$([ "$(newest onlyremove)" != "$old" ] && echo new)" "new"

echo "== combinations"
mkdir -p "$work/trees/other/x86_64-windows"
dll "$work/trees/other/x86_64-windows/dxgi.dll" other
desc other <<CONF
label = Other
variant = Backend
src = trees/other
dst = lib/dxmt
CONF
both=$(resolve 'one+other')
ok "two variants build one runner" "$both" "$(newest one+other)"
ok "the first tree is in it" "$(cat "$both/lib/dxmt/x86_64-windows/d3d11.dll" | tr -d '\000')" \
  "Wine builtin DLLtwotwotwo"
ok "the second tree is in it" "$(cat "$both/lib/dxmt/x86_64-windows/dxgi.dll" | tr -d '\000')" \
  "Wine builtin DLLother"
ok "the order asked for does not matter" "$(resolve 'other+one')" "$both"
ok "a repeated name does not repeat in the name" "$(resolve 'one+one')" "$(newest one)"
: > "$work/log"
got=$(resolve 'one+trim')
ok "two variants touching one file still build" "$got" "$(newest one+trim)"
ok "the later one's copy is used" "$(tr -d '\000' < "$got/lib/dxmt/x86_64-windows/d3d11.dll")" "Wine builtin DLLtrim"
logged "and the overlap is reported" "trim changes lib/dxmt/x86_64-windows/d3d11.dll after an earlier variant did"

echo "== a request naming something unusable"
: > "$work/log"
ok "the members that work are still used" "$(resolve 'one+gone')" "$(newest one)"
logged "and the rest is reported" "ignoring gone, which cannot be used"
ok "a request of nothing but unusable names falls back" "$(resolve 'gone+typo')" "$base"
# The runner is named for what went into it, not for what was asked for.
ok "the runner is named for the members that worked" "$(builds_of one+gone)" "0"

echo "== names"
mkdir -p "$work/trees/under/x86_64-windows"
dll "$work/trees/under/x86_64-windows/d3d11.dll" under
desc dxmt_dev <<CONF
src = trees/under
dst = lib/dxmt
CONF
got=$(resolve 'dxmt_dev')
ok "an id with an underscore is used, as the panel offers it" "$got" "$(newest dxmt_dev)"
# Build ids carry "-" too (26.3-fex is a build), so a variant named fex must not land on it.
fexbase="$work/runners/crossover-26.3-fex/CrossOver"
mkdir -p "$fexbase/lib/wine"
: > "$fexbase/lib/wine/the-fex-build"
desc fex <<CONF
src = trees/under
dst = lib/dxmt
CONF
got=$(resolve 'fex')
ok "a variant named like another build gets its own runner" "$got" "$(newest fex)"
ok "and the build it is named like is untouched" "$([ -f "$fexbase/lib/wine/the-fex-build" ] && echo kept)" "kept"

echo "== two launches at once"
: > "$work/log"
dll "$work/trees/one/x86_64-windows/d3d11.dll" racerace
resolve 'one' > "$work/race1" &
resolve 'one' > "$work/race2" &
wait
built=$(newest one)
ok "both get the runner" "$(cat "$work/race1")|$(cat "$work/race2")" "$built|$built"
ok "it holds the tree both asked for" \
  "$(tr -d '\000' < "$built/lib/dxmt/x86_64-windows/d3d11.dll")" "Wine builtin DLLracerace"
ok "it was built once" "$(grep -c 'building crossover-26.3+one@' "$work/log")" "1"
left=0
for f in "$work/runners"/.*.new "$work/runners"/.*.old; do [ ! -e "$f" ] || left=$((left + 1)); done
ok "no scratch is left behind" "$left" "0"

echo "== a live runner is left alone"
: > "$work/log"
live=$built
touch -t 202001010000 "${live%/CrossOver}/.notproton-used"
dll "$work/trees/one/x86_64-windows/d3d11.dll" threethreethree
# np_variant_busy reads the executable path of every process, as RunnerInstaller.isRunning
# does. Standing a fake ps in for one keeps the test off whether macOS will run a copied
# binary; the assumption it rests on -- that ps prints absolute paths -- is checked below.
mkdir -p "$work/fakebin"
cat > "$work/fakebin/ps" <<FAKE
#!/bin/sh
printf '%s\n' /usr/libexec/somethingelse "$live/lib/wine/x86_64-unix/wine"
FAKE
chmod +x "$work/fakebin/ps"
got=$(PATH="$work/fakebin:$PATH" resolve 'one')
ok "the next launch gets a new build beside it" "$got" "$(newest one)"
ok "holding the new tree" "$(tr -d '\000' < "$got/lib/dxmt/x86_64-windows/d3d11.dll")" "Wine builtin DLLthreethreethree"
ok "and the running one is not touched" "$(tr -d '\000' < "$live/lib/dxmt/x86_64-windows/d3d11.dll")" "Wine builtin DLLracerace"
ok "or cleaned up while it runs, however old" "$([ -d "$live" ] && echo kept)" "kept"
: > "$work/log"
cat > "$work/fakebin/ps" <<FAKE
#!/bin/sh
printf '%s\n' "$got/lib/wine/x86_64-unix/wine"
FAKE
marker="$got/lib/wine/not-from-the-tree"
: > "$marker"
ok "a forced rebuild of a running build is used as it is" "$(PATH="$work/fakebin:$PATH" resolve 'one' 1)" "$got"
ok "and not rebuilt under the game" "$([ -f "$marker" ] && echo kept)" "kept"
logged "and says why" "leaving it as it is"

echo "== a build that fails runs the last one that worked"
: > "$work/log"
good=$(resolve 'one')
native_dll "$work/trees/one/x86_64-windows/dxgi.dll"
ok "the last good build is used" "$(resolve 'one')" "$good"
logged "and says so" "the last build of it that worked"
: > "$work/log"
dll "$base/lib/wine/x86_64-windows/ntdll.dll" repatched
ok "but not once the base runner is re-patched, since it carries the old bridge" "$(resolve 'one')" "$base"
rm -f "$work/trees/one/x86_64-windows/dxgi.dll"

# shellcheck disable=SC2009 # the point is the shape of what ps prints
ok "ps really does print absolute executable paths" \
  "$(ps -axww -o comm= | sed -n 's|^\(/[^ ]*\)/[^/ ]*$|yes|p' | head -1)" "yes"

echo "== mach-o files are signed"
if command -v cc > /dev/null 2>&1; then
  printf 'int main(void) { return 0; }\n' > "$work/m.c"
  cc -o "$work/plain" "$work/m.c"
  cp "$work/plain" "$work/broken"
  codesign --remove-signature "$work/broken"
  ok "the broken binary really is broken" "$(codesign -v "$work/broken" 2>/dev/null || echo invalid)" "invalid"
  cp "$work/plain" "$base/bin/wineserver"
  cat > "$work/ent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
PLIST
  codesign -f -s - --options runtime --entitlements "$work/ent.plist" "$base/bin/wineserver" 2>/dev/null
  mkdir -p "$work/trees/signed/bin" "$work/trees/signed/lib/wine/x86_64-unix"
  cp "$work/broken" "$work/trees/signed/bin/wineserver"
  cp "$work/broken" "$work/trees/signed/lib/wine/x86_64-unix/win32u.so"
  desc signed <<CONF
src   = trees/signed
dst   = .
build = 26.3
CONF
  : > "$work/log"
  got=$(resolve 'signed')
  ok "a tree with unsigned binaries is used" "$got" "$(newest signed)"
  ok "a new file is signed so it loads" "$(codesign -v "$got/lib/wine/x86_64-unix/win32u.so" 2>/dev/null && echo valid)" "valid"
  ok "a replaced one is signed" "$(codesign -v "$got/bin/wineserver" 2>/dev/null && echo valid)" "valid"
  ok "with the entitlements of what it replaced" \
    "$(codesign -d --entitlements - --xml "$got/bin/wineserver" 2>/dev/null | grep -c disable-library-validation)" "1"
  ok "and the tree itself is not touched" "$(codesign -v "$work/trees/signed/bin/wineserver" 2>/dev/null || echo invalid)" "invalid"
  cat > "$work/restricted.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.developer.cross-architecture-support</key><true/></dict></plist>
PLIST
  codesign -f -s - --entitlements "$work/restricted.plist" "$base/bin/wineserver" 2>/dev/null
  rm -rf "$work/runners/crossover-26.3+signed"@*
  : > "$work/log"
  ok "replacing a file with an Apple-only entitlement falls back" "$(resolve 'signed')" "$base"
  logged "and says why" "would replace a file holding an entitlement only Apple can sign for"
  ok "without cloning a runner to find out" "$(grep -c 'building crossover-26.3+signed' "$work/log" || true)" "0"
else
  echo "  skip  no cc to make a Mach-O with"
fi

echo "== a prefix rereads wine.inf when its variant files change"
pfx="$work/compat/pfx"
mkdir -p "$pfx"
: > "$pfx/system.reg"
switch() {
  printf '1234\n' > "$pfx/.update-timestamp"
  STEAM_COMPAT_DATA_PATH="$work/compat" WINEPREFIX="$pfx" np_variant_layout="$1" log="$work/log" \
    sh -c "$switch_fn
note_variant_switch"
  cat "$pfx/.update-timestamp"
}
ok "a prefix that never ran a variant is left alone" "$(switch '')" "1234"
ok "the first variant has it update" "$(switch aaa)" "0"
ok "the same files again do not" "$(switch aaa)" "1234"
ok "a different set does" "$(switch bbb)" "0"
ok "and so does going back to the stock runner" "$(switch '')" "0"
ok "which then stays put" "$(switch '')" "1234"
rm -f "$pfx/system.reg"
ok "a prefix not made yet is not touched" "$(switch ccc)" "1234"
echo "== a new module name is registered in the game's prefix"
# A variant can bring a module name the base runner never had. Prefixes are copied from a
# template built before the variant existed, so that name has no entry in system32 and a
# forward into it fails with "module not found". Giving the prefix the file registers the
# name; a name it already has resolves on its own and must be left alone.
: > "$work/log"
mkdir -p "$base/lib/dxmt/i386-windows"
mkdir -p "$work/trees/pair/x86_64-windows" "$work/trees/pair/i386-windows"
dll "$work/trees/pair/x86_64-windows/newmod.dll" src64
dll "$work/trees/pair/i386-windows/newmod.dll" src32
dll "$work/trees/pair/x86_64-windows/d3d11.dll" srcold
desc pair <<CONF
label = Pair
variant = Backend
src = trees/pair
dst = lib/dxmt
CONF
stage() {
  NOTPROTON_RUNNER_VARIANT="$1" HOME="$work" np_support="$work" np_build="26.3" \
    np_flavor=rosetta log="$work/log" PATH="$PATH" WINEPREFIX="$2" \
    sh -c '. "$1/block.sh"; np_variant_stage_prefix' sh "$work"
}
pfx="$work/pfx"
mkdir -p "$pfx/drive_c/windows/system32" "$pfx/drive_c/windows/syswow64"
native_dll "$pfx/drive_c/windows/system32/d3d11.dll"
prefixed() { tr -d '\000' < "$1" 2>/dev/null || true; }

stage pair "$pfx"
ok "the 64-bit module lands in system32" \
  "$(prefixed "$pfx/drive_c/windows/system32/newmod.dll")" "Wine builtin DLLsrc64"
ok "the 32-bit module lands in syswow64" \
  "$(prefixed "$pfx/drive_c/windows/syswow64/newmod.dll")" "Wine builtin DLLsrc32"
# The prefix gets what the runner ended up with, which is the copy checked for the marker.
ok "it is the runner's copy, not the tree it was built from" \
  "$(cmp -s "$pfx/drive_c/windows/system32/newmod.dll" \
      "$(newest pair)/lib/dxmt/x86_64-windows/newmod.dll" \
      && echo same)" "same"
ok "a name the prefix already has is left alone" \
  "$(prefixed "$pfx/drive_c/windows/system32/d3d11.dll")" ""
logged "and says what it registered" "pair: registered newmod.dll in system32"

# Staging runs on every launch, so saying it twice must not mean doing it twice.
: > "$work/log"
stage pair "$pfx"
ok "a second launch registers nothing again" \
  "$(grep -c registered "$work/log" || true)" "0"

# A 64-bit-only prefix has no syswow64 to put the 32-bit module in.
: > "$work/log"
narrow="$work/pfx64"
mkdir -p "$narrow/drive_c/windows/system32"
stage pair "$narrow"
ok "a prefix without syswow64 still gets the 64-bit module" \
  "$(prefixed "$narrow/drive_c/windows/system32/newmod.dll")" "Wine builtin DLLsrc64"
ok "and nothing is invented for the missing directory" \
  "$([ -e "$narrow/drive_c/windows/syswow64" ] || echo absent)" "absent"

# Nothing to register when no variant was used, which is most launches.
: > "$work/log"
stage '' "$pfx"
ok "no variant registers nothing" "$(grep -c registered "$work/log" || true)" "0"

dll "$work/trees/pair/x86_64-windows/newmod.dll" src64v2
stage pair "$pfx"
ok "a rebuild refreshes what it registered" \
  "$(prefixed "$pfx/drive_c/windows/system32/newmod.dll")" "Wine builtin DLLsrc64v2"
ok "and still leaves the prefix's own file" \
  "$(prefixed "$pfx/drive_c/windows/system32/d3d11.dll")" ""
ok "with no temp file left behind" "$(ls "$pfx/drive_c/windows/system32" | grep -c np-stage || true)" "0"

mkdir -p "$base/lib/dxmt/aarch64-windows"
mkdir -p "$work/trees/both/x86_64-windows" "$work/trees/both/aarch64-windows"
dll "$work/trees/both/x86_64-windows/bothmod.dll" x64
dll "$work/trees/both/aarch64-windows/bothmod.dll" arm64
desc both <<CONF
label = Both
variant = Backend
src = trees/both
dst = lib/dxmt
CONF
stage both "$pfx"
ok "a Rosetta prefix gets the x86_64 copy" \
  "$(prefixed "$pfx/drive_c/windows/system32/bothmod.dll")" "Wine builtin DLLx64"

echo "== file names in another case"
mkdir -p "$work/trees/upper/x86_64-windows"
dll "$work/trees/upper/x86_64-windows/ok.dll" ok
dll "$work/trees/upper/x86_64-windows/NTDLL.DLL" bad
desc upper <<CONF
src = trees/upper
dst = lib/wine
build = 26.3
CONF
: > "$work/log"
ok "an upper-case ntdll falls back" "$(resolve 'upper')" "$base"
logged "and names it" "would change lib/wine/x86_64-windows/ntdll.dll"
mkdir -p "$work/trees/nomark/x86_64-windows"
native_dll "$work/trees/nomark/x86_64-windows/FOO.DLL"
desc nomark <<CONF
src = trees/nomark
dst = lib/dxmt
CONF
: > "$work/log"
ok "an upper-case DLL with no builtin mark falls back" "$(resolve 'nomark')" "$base"
logged "and says why" "is not marked as a Wine builtin"
if command -v cc > /dev/null 2>&1; then
  mkdir -p "$work/trees/ext/x86_64-unix"
  printf 'int main(void) { return 0; }\n' > "$work/ext.c"
  cc -o "$work/trees/ext/x86_64-unix/libfoo.so.1" "$work/ext.c"
  codesign --remove-signature "$work/trees/ext/x86_64-unix/libfoo.so.1"
  desc ext <<CONF
src = trees/ext
dst = lib/dxmt
CONF
  got=$(resolve 'ext')
  ok "a Mach-O named libfoo.so.1 is signed" \
    "$(codesign -v "$got/lib/dxmt/x86_64-unix/libfoo.so.1" 2>/dev/null && echo valid)" "valid"
else
  echo "  skip  no cc to make a Mach-O with"
fi

echo "== cleaning up old builds"
mkdir -p "$work/trees/gc/x86_64-windows"
dll "$work/trees/gc/x86_64-windows/gc.dll" one
desc gc <<CONF
src = trees/gc
dst = lib/dxmt
CONF
resolve gc > /dev/null
old=$(newest gc); old=${old%/CrossOver}
dll "$work/trees/gc/x86_64-windows/gc.dll" twotwo
touch -t 202001010000 "$old/.notproton-used"
mkdir -p "$work/failps" "$work/keeprm"
printf '#!/bin/sh\nexit 1\n' > "$work/failps/ps"
cat > "$work/keeprm/rm" <<'FAKE'
#!/bin/sh
case "$*" in *.removing*) exit 1 ;; esac
exec /bin/rm "$@"
FAKE
chmod +x "$work/failps/ps" "$work/keeprm/rm"
( PATH="$work/failps:$PATH"; resolve gc > /dev/null )
ok "a ps that fails keeps the old build" "$([ -d "$old" ] && echo kept)" "kept"
touch -t 202001010000 "$old/.notproton-used"
( PATH="$work/keeprm:$PATH"; resolve gc > /dev/null )
ok "a cleanup killed partway leaves no build under the old name" "$([ -e "$old" ] || echo gone)" "gone"
trash="$work/runners/.${old##*/}.removing"
ok "only its hidden trash" "$([ -d "$trash" ] && echo there)" "there"
scratch="$work/runners/.crossover-26.3+gc@deadbeef0000"
mkdir -p "$scratch.new" "$scratch.old"
( exec 7>> "$work/runners/.crossover-26.3+gc.lock"; /usr/bin/lockf -s -t 0 7; sleep 3 ) &
held=$!
sleep 1
resolve gc > /dev/null
ok "leftovers stay while a build holds the lock" "$([ -d "$scratch.new" ] && echo kept)" "kept"
wait "$held"
resolve gc > /dev/null
ok "and go once it doesn't" "$([ -e "$scratch.new" ] || [ -e "$scratch.old" ] || [ -e "$trash" ] || echo gone)" "gone"

[ "$fail" -eq 0 ] || exit 1
echo "==> runnervariantcheck: variants build on demand, refuse bad trees and fall back"
