#!/bin/sh
# shellcheck disable=SC2016,SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "launchercheck: $SRC not present, skipped"; exit 0; }

funcs=$(sed -n '/^bundle_listing() {$/,/^)$/p' "$SRC")
runner_funcs=$(sed -n '/^runner_stamp() {$/,/^)$/p' "$SRC")
runner_pick=$(sed -n '/^game_runner=""$/,/^fi$/p' "$SRC")
name_lines=$(sed -n '/^bundle_name=\$(printf/,/^\[ -n "\$bundle_name" \] || bundle_name=/p' "$SRC")
launcher_body=$(sed -n '/^  cat > "\$loader_macos\/launcher" <<LAUNCHER$/,/^LAUNCHER$/p' "$SRC" | sed 1d)
loader_line=$(grep -A1 '^  if \[ -x "\$loader_macos/wine" \]; then$' "$SRC" | sed -n 2p)
[ -n "$funcs" ] || { echo "FAIL: bundle functions not found"; exit 1; }
[ -n "$name_lines" ] || { echo "FAIL: bundle name lines not found"; exit 1; }
[ -n "$launcher_body" ] || { echo "FAIL: launcher script not found"; exit 1; }
[ -n "$runner_funcs" ] && [ -n "$runner_pick" ] || { echo "FAIL: runner copy code not found"; exit 1; }
eval "$funcs"

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/runner"
printf 'a' > "$T/runner/a.so"
printf 'b' > "$T/runner/b.so"
log="$T/log"
loader_root="$T/launchers"
mkdir -p "$loader_root"

stage() {
  loader_app="$loader_root/$1.app"
  loader_work=$(mktemp -d "$loader_root/.build.XXXXXX")
  loader_stage="$loader_work/new/$1.app"
  mkdir -p "$loader_stage/Contents/MacOS" "$loader_stage/Contents/Resources"
  printf '%s' "${2:-plist}" > "$loader_stage/Contents/Info.plist"
  printf 'icon' > "$loader_stage/Contents/Resources/game.icns"
  ln -sfn "$T/runner/${3:-a.so}" "$loader_stage/Contents/MacOS/x.so"
  printf '#!/bin/sh\n' > "$loader_stage/Contents/MacOS/launcher"
  chmod "${4:-755}" "$loader_stage/Contents/MacOS/launcher"
  : > "$log"
}
build() {
  stage "$@"
  install_bundle
}
apps() { (cd "$loader_root" && for b in *.app; do [ -e "$b" ] && printf '%s|' "$b"; done; true); }
plist_inode() { stat -f %i "$loader_app/Contents/Info.plist"; }
leftover() { (cd "$loader_root" && n=0 && for b in .build.*; do [ -e "$b" ] && n=$((n + 1)); done; echo "$n"); }

echo "== final paths =="
case "$launcher_body" in *loader_stage*|*loader_contents*|*loader_macos*|*loader_work*) bad "launcher has no staging paths" "none" "staging path" ;; *) ok "launcher has no staging paths" ;; esac
is "WINELOADER points at the installed bundle" '    WINELOADER="$loader_app/Contents/MacOS/wine"' "$loader_line"

echo "== bundle names =="
for pair in '.hack//G.U. Last Recode|hackG.U. Last Recode' '...|Steam Game' '//|Steam Game' 'Half-Life 2|Half-Life 2' 'a.b|a.b'; do
  game_name=${pair%%|*}
  eval "$name_lines"
  is "name [${pair%%|*}]" "${pair#*|}" "$bundle_name"
done

echo "== first launch =="
build "Game"
is "bundle created" "Game.app|" "$(apps)"
is "logged as updated" "launcher bundle updated" "$(cat "$log")"
is "work folder removed" "0" "$(leftover)"

echo "== same content =="
before=$(plist_inode)
build "Game"
is "logged as unchanged" "launcher bundle unchanged" "$(cat "$log")"
is "bundle kept in place" "$before" "$(plist_inode)"
is "work folder removed" "0" "$(leftover)"

echo "== changes replace the bundle =="
build "Game" "plist2"
is "plist change" "launcher bundle updated" "$(cat "$log")"
is "new plist in place" "plist2" "$(cat "$loader_app/Contents/Info.plist")"
build "Game" "plist2" "b.so"
is "symlink target change" "launcher bundle updated" "$(cat "$log")"
is "new symlink in place" "$T/runner/b.so" "$(readlink "$loader_app/Contents/MacOS/x.so")"
build "Game" "plist2" "b.so" 644
is "mode change" "launcher bundle updated" "$(cat "$log")"
build "Game" "plist2" "b.so" 644
is "then unchanged" "launcher bundle unchanged" "$(cat "$log")"
rm "$loader_app/Contents/Resources/game.icns"
build "Game" "plist2" "b.so" 644
is "missing file" "launcher bundle updated" "$(cat "$log")"

echo "== renames =="
build "Other Name"
is "old name removed" "Other Name.app|" "$(apps)"
build "OTHER NAME"
is "case-only rename" "OTHER NAME.app|" "$(apps)"
is "case-only rename replaced" "launcher bundle updated" "$(cat "$log")"
build "OTHER NAME"
is "then unchanged" "launcher bundle unchanged" "$(cat "$log")"

echo "== stray bundles =="
mkdir -p "$loader_root/Stray.app"
build "OTHER NAME"
is "stray removed when unchanged" "OTHER NAME.app|" "$(apps)"
is "still unchanged" "launcher bundle unchanged" "$(cat "$log")"

mkdir -p "$loader_root/.Hidden.app"
build "OTHER NAME"
is "hidden stray removed when unchanged" "0" "$(find "$loader_root" -maxdepth 1 -name '.Hidden.app' | wc -l | tr -d ' ')"
mkdir -p "$loader_root/.Hidden.app"
build "OTHER NAME" "plist3"
is "hidden stray removed when updated" "0" "$(find "$loader_root" -maxdepth 1 -name '.Hidden.app' | wc -l | tr -d ' ')"
build "OTHER NAME"

echo "== awkward names =="
name='Sonic Adventure™ 2 [x]*? '
build "$name"
build "$name"
is "glob characters and trailing space" "launcher bundle unchanged" "$(cat "$log")"
is "only that bundle" "$name.app|" "$(apps)"

echo "== hardlink and copy compare equal =="
mkdir -p "$T/a" "$T/b"
printf 'wine' > "$T/loader"
ln "$T/loader" "$T/a/wine"
cp "$T/loader" "$T/b/wine"
is "same listing" "$(bundle_listing "$T/a")" "$(bundle_listing "$T/b")"

echo "== lock =="
build "OTHER NAME"
if /usr/bin/lockf -s -t 0 "$loader_root/.lock" true; then ok "lock released"; else bad "lock released" "free" "held"; fi

echo "== case twin =="
rm -rf "$loader_root"/*.app
mkdir -p "$loader_root/Twin.APP"
if [ -d "$loader_root/Twin.app" ]; then
  build "Twin"
  is "twin replaced" "Twin.app|" "$(apps)"
else
  ok "volume is case-sensitive, skipped"
fi

echo "== symlinked bundle =="
mkdir -p "$T/elsewhere.app"
rm -rf "$loader_root"/*.app
ln -s "$T/elsewhere.app" "$loader_root/Linked.app"
build "Linked"
is "symlink replaced by a real bundle" "launcher bundle updated" "$(cat "$log")"
if [ -L "$loader_root/Linked.app" ]; then bad "not a symlink" "dir" "symlink"; else ok "not a symlink"; fi
if [ -d "$T/elsewhere.app" ]; then ok "symlink target untouched"; else bad "symlink target untouched" "present" "gone"; fi

echo "== lock contention =="
build "Original"
before=$(plist_inode)
stage "Replacement"
exec 8>> "$loader_root/.lock"
/usr/bin/lockf -s -t 0 8
if (exec 8>&-; install_bundle); then
  bad "busy lock refuses installation" "failure" "success"
else
  ok "busy lock refuses installation"
fi
is "locked bundle untouched" "$before" "$(stat -f %i "$loader_root/Original.app/Contents/Info.plist")"
is "no replacement without lock" "Original.app|" "$(apps)"
exec 8>&-
install_bundle
is "retry after unlock succeeds" "Replacement.app|" "$(apps)"

echo "== rollback =="
for failure in install backup signal signal-installed missing-stage restore; do
  build "Original"
  before=$(plist_inode)
  mkdir -p "$loader_root/.Hidden.app" "$loader_root/Stray.app"
  stage "Replacement"
  staged_inode=$(stat -f %i "$loader_stage/Contents/Info.plist")
  if env funcs="$funcs" failure="$failure" loader_root="$loader_root" loader_app="$loader_app" \
      loader_work="$loader_work" loader_stage="$loader_stage" log="$log" /bin/sh -c '
    set -e
    eval "$funcs"
    mv() {
      case "$failure" in
        install|restore) [ "$1" != "$loader_stage" ] || return 1 ;;
        backup) [ "$1" != "$loader_root/Stray.app" ] || return 1 ;;
        missing-stage)
          if [ "$1" = "$loader_stage" ]; then rm -rf "$loader_stage"; return 1; fi ;;
      esac
      if [ "$failure" = restore ]; then
        case "$1" in "$loader_root"/.backup.*/Original.app) return 1 ;; esac
      fi
      command mv "$@" || return 1
      if [ "$failure" = signal ] && [ "$1" = "$loader_root/Original.app" ]; then
        /bin/sh -c '\''kill -TERM "$PPID"'\''
      fi
      if [ "$failure" = signal-installed ] && [ "$1" = "$loader_stage" ]; then
        /bin/sh -c '\''kill -TERM "$PPID"'\''
      fi
    }
    install_bundle
  '; then
    bad "$failure reports failure" "failure" "success"
  else
    ok "$failure reports failure"
  fi
  if [ "$failure" = signal-installed ]; then
    is "signal after rename keeps new bundle" "$staged_inode" "$(plist_inode)"
    is "signal after rename does not nest old bundles" "Replacement.app|" "$(apps)"
    is "signal after rename cleans staging" "0" "$(leftover)"
    if /usr/bin/lockf -s -t 0 "$loader_root/.lock" true; then ok "$failure releases lock"; else bad "$failure releases lock" "free" "held"; fi
    continue
  fi
  if [ "$failure" = restore ]; then
    is "failed rollback preserves backup" "$before" "$(stat -f %i "$loader_root"/.backup.*/Original.app/Contents/Info.plist)"
    mv "$loader_root"/.backup.*/Original.app "$loader_root/Original.app"
    rmdir "$loader_root"/.backup.*
  fi
  is "$failure keeps original name and inode" "$before" "$(stat -f %i "$loader_root/Original.app/Contents/Info.plist")"
  is "$failure restores visible bundles" "Original.app|Stray.app|" "$(apps)"
  if [ -d "$loader_root/.Hidden.app" ]; then ok "$failure keeps hidden bundle"; else bad "$failure keeps hidden bundle" "present" "missing"; fi
  if /usr/bin/lockf -s -t 0 "$loader_root/.lock" true; then ok "$failure releases lock"; else bad "$failure releases lock" "free" "held"; fi
  is "$failure cleans staging" "0" "$(leftover)"
done

echo "== launch Dock icon =="
icon_funcs=$(sed -n '/^find_client_root() {$/,/^case "\$verb" in$/p' "$SRC" | sed '$d')
icon_lines=$(sed -n '/^icon_arg=""$/,/^\[ -n "\$icon_arg" \] ||/p' "$SRC")
[ -n "$icon_funcs" ] && [ -n "$icon_lines" ] || { echo "FAIL: launch icon code not found"; exit 1; }
eval "$icon_funcs"
np_support="$T/support"
iconmaker="$np_support/iconmaker"
mkdir -p "$np_support" "$T/steam/appcache/librarycache/100"
printf '#!/bin/sh\nprintf "icon=abc123\\n"\n' > "$np_support/appinfo"
printf '#!/bin/sh\ncp "$1" "$2"\n' > "$iconmaker"
chmod 755 "$np_support/appinfo" "$iconmaker"
: > "$T/steam/appcache/appinfo.vdf"
printf 'game art' > "$T/steam/appcache/librarycache/100/abc123.jpg"
app_id=100
target=""
find_client_root "$T/steam/Steam.AppBundle/Steam/Contents/MacOS"
read_app_meta
loader_root="$T/launchers/100"
loader_res="$loader_root/new/Contents/Resources"
mkdir -p "$loader_res"
: > "$log"
eval "$icon_lines"
is "icon key set" "  <key>CFBundleIconFile</key><string>game</string>" "$icon_arg"
is "bundle gets the artwork" "game art" "$(cat "$loader_res/game.icns")"
is "artwork cached with the launcher" "game art" "$(cat "$loader_root/game.icns")"
is "artwork built" "icon built from $T/steam/appcache/librarycache/100/abc123.jpg" "$(cat "$log")"
rm -f "$iconmaker" "$loader_res/game.icns"
: > "$log"
eval "$icon_lines"
is "cached artwork reused" "icon reused from $T/steam/appcache/librarycache/100/abc123.jpg" "$(cat "$log")"
is "reused artwork copied" "game art" "$(cat "$loader_res/game.icns")"
rm "$T/steam/appcache/librarycache/100/abc123.jpg" "$loader_res/game.icns"
: > "$log"
eval "$icon_lines"
is "no artwork, no icon key" "" "$icon_arg"
is "no artwork logged" "no icon resolved, launching without one" "$(cat "$log")"
if [ -d "$np_support/shortcut-icons" ]; then bad "launch leaves shortcut cache alone" "absent" "present"; else ok "launch leaves shortcut cache alone"; fi

echo "== session lasts as long as the shim =="
session_trap=$(sed -n '/^terminate() {$/,/^trap terminate TERM INT HUP$/p' "$SRC")
session_wait=$(sed -n '/^open_pid=\$!$/,/^exit \$status$/p' "$SRC")
[ -n "$session_trap" ] && [ -n "$session_wait" ] || { echo "FAIL: session code not found"; exit 1; }
{
  printf 'log=%s\nopen() { sleep "$1"; return "$2"; }\n' "$T/session.log"
  printf 'kill_wine_prefix() { echo kill >> "%s"; }\n' "$T/session.ev"
  printf '%s\n' "$session_trap"
  printf 'open "$1" "$2" &\n'
  printf '%s\n' "$session_wait"
} > "$T/session.sh"
: > "$T/session.ev"
start=$(date +%s)
rc=0; sh "$T/session.sh" 3 7 || rc=$?
is "the shim's exit status is the session's" 7 "$rc"
is "the session waits for the shim" yes "$([ $(($(date +%s) - start)) -ge 3 ] && echo yes || echo no)"
is "the prefix is torn down once" kill "$(cat "$T/session.ev")"
: > "$T/session.ev"
start=$(date +%s)
sh "$T/session.sh" 30 0 & sp=$!
sleep 1
kill -TERM "$sp"
rc=0; wait "$sp" || rc=$?
is "exit game ends the session" 143 "$rc"
is "exit game does not wait out the shim" yes "$([ $(($(date +%s) - start)) -lt 5 ] && echo yes || echo no)"
is "exit game tears the prefix down" yes "$(grep -q kill "$T/session.ev" && echo yes || echo no)"

echo "== runner copy =="
eval "$runner_funcs"
pick() {
  wine_unix="$1"; user_dllpath="$2"; loader_root="$T/game"; NOTPROTON_HIDE_LAUNCHER_TILE=0
  eval "$runner_pick"
}
pick /cx/lib/wine/aarch64-unix ""
is "FEX runner" "$T/game/runner|wine" "$game_runner|$bundle_exec"
is "Dock tile hidden" "  <key>LSUIElement</key><true/>" "$uielement_arg"
pick /cx/lib/wine/aarch64-unix /extra
is "own WINEDLLPATH" "|launcher" "$game_runner|$bundle_exec"
pick /cx/lib/wine/x86_64-unix ""
is "Rosetta runner" "$T/game/runner/lib/wine/x86_64-unix/wine.app|wine" "$game_app|$bundle_exec"

CX_ROOT="$T/cx"
wine_unix="$CX_ROOT/lib/wine/aarch64-unix"
mkdir -p "$wine_unix/wine.app/Contents/MacOS" "$wine_unix/wine.app/Contents/_CodeSignature" \
  "$CX_ROOT/lib/wine/x86_64-windows" "$CX_ROOT/lib/wine/aarch64-windows" "$CX_ROOT/lib/other" "$CX_ROOT/share"
printf 'wine' > "$wine_unix/wine.app/Contents/MacOS/wine"
printf 'so' > "$wine_unix/ntdll.so"
printf 'dll' > "$CX_ROOT/lib/wine/x86_64-windows/lsteamclient.dll"
loader_root="$T/game"
game_runner="$loader_root/runner"
game_app="$game_runner/lib/wine/aarch64-unix/wine.app"
mkdir -p "$loader_root"
runner_build() {
  loader_work=$(mktemp -d "$loader_root/.build.XXXXXX")
  loader_contents="$loader_work/new/Game.app/Contents"
  loader_res="$loader_contents/Resources"
  mkdir -p "$loader_res"
  printf '%s' "${1:-plist}" > "$loader_contents/Info.plist"
  printf '%s' "${2:-icon}" > "$loader_res/game.icns"
  : > "$log"
  install_game_runner
}
mkdir -p "$loader_root/Old.app"
runner_build
is "first clone" "cloned $CX_ROOT for this game|game's wine.app updated" "$(paste -sd '|' "$log")"
is "Info.plist" "plist" "$(cat "$game_app/Contents/Info.plist")"
is "icon" "icon" "$(cat "$game_app/Contents/Resources/game.icns")"
is "signature removed" no "$([ -e "$game_app/Contents/_CodeSignature" ] && echo yes || echo no)"
is "runner still signed" yes "$([ -e "$wine_unix/wine.app/Contents/_CodeSignature" ] && echo yes || echo no)"
is "lsteamclient in aarch64-windows" "dll" "$(cat "$game_runner/lib/wine/aarch64-windows/lsteamclient.dll")"
is "lib/wine copied" no "$([ -L "$game_runner/lib/wine" ] && echo yes || echo no)"
is "ntdll.so copied" no "$([ -L "$game_runner/lib/wine/aarch64-unix/ntdll.so" ] && echo yes || echo no)"
is "lib symlinks" "$CX_ROOT/lib/other" "$(readlink "$game_runner/lib/other")"
is "runner symlinks" "$CX_ROOT/share" "$(readlink "$game_runner/share")"
is "old launcher gone" "" "$(apps)"
is "cleanup" "0" "$(leftover)"
before=$(stat -f %i "$game_runner/lib/wine/aarch64-unix/ntdll.so")
runner_build
is "reuse" "game's wine.app already up to date" "$(cat "$log")"
is "clone reused" "$before" "$(stat -f %i "$game_runner/lib/wine/aarch64-unix/ntdll.so")"
runner_build plist2 icon2
is "rename" "game's wine.app updated" "$(cat "$log")"
is "new Info.plist" "plist2" "$(cat "$game_app/Contents/Info.plist")"
is "new icon" "icon2" "$(cat "$game_app/Contents/Resources/game.icns")"
printf 'dll2' > "$T/new.dll"
mv "$T/new.dll" "$CX_ROOT/lib/wine/x86_64-windows/lsteamclient.dll"
runner_build plist2 icon2
is "reclone after patch" "cloned $CX_ROOT for this game|game's wine.app updated" "$(paste -sd '|' "$log")"
is "patched lsteamclient" "dll2" "$(cat "$game_runner/lib/wine/aarch64-windows/lsteamclient.dll")"
is "cleanup after reclone" "0" "$(leftover)"
sleep 1
printf 'restored wine' > "$wine_unix/wine.app/Contents/MacOS/wine"
runner_build plist2 icon2
is "reclone after in-place write" "restored wine" "$(cat "$game_app/Contents/MacOS/wine")"
rm "$CX_ROOT/lib/wine/x86_64-windows/lsteamclient.dll"
if runner_build plist3; then bad "clone failure" "failure" "success"; else ok "clone failure"; fi
is "clone failure cleanup" "0" "$(leftover)"
if /usr/bin/lockf -s -t 0 "$loader_root/.lock" true; then ok "lock released"; else bad "lock released" "free" "held"; fi


CX_ROOT="$T/cx-rosetta"
wine_unix="$CX_ROOT/lib/wine/x86_64-unix"
mkdir -p "$wine_unix" "$CX_ROOT/lib/wine/x86_64-windows"
printf 'x86 wine' > "$wine_unix/wine"
printf 'so' > "$wine_unix/ntdll.so"
loader_root="$T/game-rosetta"
game_runner="$loader_root/runner"
game_app="$game_runner/lib/wine/x86_64-unix/wine.app"
mkdir -p "$loader_root"
runner_build
is "Rosetta first clone" "cloned $CX_ROOT for this game|game's wine.app updated" "$(paste -sd '|' "$log")"
is "Rosetta wine.app" "x86 wine" "$(cat "$game_app/Contents/MacOS/wine")"
is "Rosetta wine copied" no "$([ "$game_app/Contents/MacOS/wine" -ef "$wine_unix/wine" ] && echo yes || echo no)"
is "Rosetta runner untouched" no "$([ -e "$wine_unix/wine.app" ] && echo yes || echo no)"
is "Rosetta Info.plist" "plist" "$(cat "$game_app/Contents/Info.plist")"
is "Rosetta no aarch64-windows" no "$([ -e "$game_runner/lib/wine/aarch64-windows" ] && echo yes || echo no)"
runner_build
is "Rosetta reuse" "game's wine.app already up to date" "$(cat "$log")"
printf 'x86 wine 2' > "$T/new-wine"
mv "$T/new-wine" "$wine_unix/wine"
runner_build
is "Rosetta reclone after re-sign" "x86 wine 2" "$(cat "$game_app/Contents/MacOS/wine")"

[ "$fails" -eq 0 ] || { echo "launchercheck: $fails failed"; exit 1; }
echo "launchercheck: all passed"
