#!/bin/sh
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "launchercheck: $SRC not present, skipped"; exit 0; }

funcs=$(sed -n '/^bundle_listing() {$/,/^)$/p' "$SRC")
runner_funcs=$(sed -n '/^runner_stamp() {$/,/^)$/p' "$SRC")
runner_pick=$(sed -n '/^game_runner=""$/,/^fi$/p' "$SRC")
shared_funcs=$(sed -n '/^lsregister="\/System/,/^case "\$verb" in$/p' "$SRC" | sed '$d')
launcher_body=$(sed -n '/^  cat > "\$loader_macos\/launcher" <<LAUNCHER$/,/^LAUNCHER$/p' "$SRC" | sed 1d)
loader_line=$(grep -A1 '^  if \[ -x "\$loader_macos/wine" \]; then$' "$SRC" | sed -n 2p)
[ -n "$funcs" ] || { echo "FAIL: bundle functions not found"; exit 1; }
[ -n "$shared_funcs" ] || { echo "FAIL: shared bundle functions not found"; exit 1; }
[ -n "$launcher_body" ] || { echo "FAIL: launcher script not found"; exit 1; }
[ -n "$runner_funcs" ] && [ -n "$runner_pick" ] || { echo "FAIL: runner copy code not found"; exit 1; }
eval "$funcs"
eval "$shared_funcs"

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

echo "== bundles =="
plist_lines=$(sed -n '/^steam_url="steam:\/\/rungameid\/\$app_id"$/,/^fi$/p' "$SRC")
gameid_func=$(sed -n '/^shortcut_game_id() {$/,/^}$/p' "$SRC")
[ -n "$plist_lines" ] && [ -n "$gameid_func" ] || { echo "FAIL: bundle plist code not found"; exit 1; }
eval "$gameid_func"
printf '#!/bin/sh\necho "open $*"\n' > "$T/open"
printf '#!/bin/sh\necho "wine $*"\n' > "$T/wine"
chmod 755 "$T/open" "$T/wine"
key() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || echo "-"; }
bundles() (
  macos=$1 game_runner=$2 SteamGameId=$3 app_id=100 game_name_xml=Game display_name_xml=$4 icon_arg=""
  uielement_arg="" localized_arg=""
  [ -z "$game_runner" ] || uielement_arg="  <key>LSUIElement</key><true/>"
  # shellcheck disable=SC2329
  sw_vers() { echo "$macos"; }
  loader_work="$T/plists" loader_contents="$T/plists/tile/Contents" loader_macos="$T/plists/tile/Contents/MacOS"
  rm -rf "$loader_work"; mkdir -p "$loader_macos"
  eval "$plist_lines"
)
bundles 27.1 runner "" wine
r="$T/plists/runner.plist" t="$T/plists/tile/Contents/Info.plist"
is "runner identity" "com.notproton.launcher.100|wine|true" "$(key "$r" CFBundleIdentifier)|$(key "$r" CFBundleExecutable)|$(key "$r" LSUIElement)"
is "runner out of the Games app" "-|true" "$(key "$r" LSApplicationCategoryType)|$(key "$r" LSSupportsGameMode)"
is "tile identity" "com.notproton.game.100|launcher|Game|-" "$(key "$t" CFBundleIdentifier)|$(key "$t" CFBundleExecutable)|$(key "$t" CFBundleDisplayName)|$(key "$t" LSUIElement)"
is "tile in the Games app" "public.app-category.games" "$(key "$t" LSApplicationCategoryType)"
sed -i '' "s|/usr/bin/open|$T/open|" "$T/plists/tile/Contents/MacOS/launcher"
is "tile hands off" "open steam://rungameid/100" "$("$T/plists/tile/Contents/MacOS/launcher")"
is "tile ignores arguments" "open steam://rungameid/100" "$("$T/plists/tile/Contents/MacOS/launcher" -psn_0_1)"
(export NOTPROTON_HIDE_LAUNCHER_TILE=1; bundles 27.1 runner "" wine)
is "hide setting leaves the tile alone" "-|public.app-category.games" "$(key "$t" LSUIElement)|$(key "$t" LSApplicationCategoryType)"
bundles 15.7 runner "" wine
is "runner before macOS 26" "public.app-category.games|-" "$(key "$r" LSApplicationCategoryType)|$(key "$r" LSSupportsGameMode)"
bundles 27.1 runner 12884901888033554432 wine
sed -i '' "s|/usr/bin/open|$T/open|" "$T/plists/tile/Contents/MacOS/launcher"
is "shortcut" "open steam://rungameid/12884901888033554432" "$("$T/plists/tile/Contents/MacOS/launcher")"
bundles 27.1 "" "" Game
is "own WINEDLLPATH bundle" "com.notproton.launcher.100|launcher|public.app-category.games" \
  "$(key "$t" CFBundleIdentifier)|$(key "$t" CFBundleExecutable)|$(key "$t" LSApplicationCategoryType)"
is "own WINEDLLPATH has no runner plist" "no" "$([ -e "$r" ] && echo yes || echo no)"
loader_launcher() (
  WINELOADER="$T/wine" loader_root="$T/plists" steam_url="steam://rungameid/100"
  eval "cat <<LAUNCHER
$launcher_body" | sed "s|/usr/bin/open|$T/open|" > "$T/loader-launcher"
  chmod 755 "$T/loader-launcher"
  "$T/loader-launcher" "$@"
  cat "$T/plists/notproton-wine.log" 2>/dev/null
)
is "own WINEDLLPATH, standalone" "open steam://rungameid/100" "$(loader_launcher)"
is "own WINEDLLPATH, psn" "open steam://rungameid/100" "$(loader_launcher -psn_0_1)"
is "own WINEDLLPATH, game" "wine game.exe" "$(loader_launcher game.exe)"

echo "== bundle names =="
for pair in '.hack//G.U. Last Recode|hackG.U. Last Recode' '...|Steam Game' '//|Steam Game' 'Half-Life 2|Half-Life 2' 'a.b|a.b'; do
  game_name=${pair%%|*}
  np_game_names
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
rm "$T/steam/appcache/librarycache/100/abc123.jpg" "$loader_res/game.icns" "$loader_root/game.icns"
printf '#!/bin/sh\ncp "$1" "$2"\n' > "$iconmaker"
chmod 755 "$iconmaker"
mkdir -p "$T/steam/appcache/librarycache/100/def"
printf 'capsule art' > "$T/steam/appcache/librarycache/100/def/library_capsule.jpg"
: > "$log"
eval "$icon_lines"
is "capsule" "icon built from $T/steam/appcache/librarycache/100/def/library_capsule.jpg" "$(cat "$log")"
is "capsule content" "capsule art" "$(cat "$loader_res/game.icns")"
rm -f "$loader_res/game.icns" "$loader_root/game.icns"
printf '#!/bin/sh\ncase "$1" in *.ico) exit 1 ;; esac\ncp "$1" "$2"\n' > "$iconmaker"
printf 'bad icon' > "$loader_root/clienticon-def456.ico"
meta_clienticon=def456
: > "$log"
eval "$icon_lines"
is "unreadable client icon" "discarded unreadable client icon def456
icon built from $T/steam/appcache/librarycache/100/def/library_capsule.jpg" "$(cat "$log")"
is "unreadable client icon content" "capsule art" "$(cat "$loader_res/game.icns")"
is "clienticon kept" "def456" "$meta_clienticon"
if [ -e "$loader_root/clienticon-def456.ico" ]; then bad "client icon dropped" "absent" "present"; else ok "client icon dropped"; fi
meta_clienticon=""
rm -rf "$T/steam/appcache/librarycache/100/def" "$loader_res/game.icns" "$loader_root/game.icns"
printf '#!/bin/sh\ncp "$1" "$2"\n' > "$iconmaker"
printf 'logo art' > "$T/steam/appcache/librarycache/100/logo.png"
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
is "FEX runner" "$T/game/runner" "$game_runner"
is "Dock tile hidden" "  <key>LSUIElement</key><true/>" "$uielement_arg"
pick /cx/lib/wine/aarch64-unix /extra
is "own WINEDLLPATH" "" "$game_runner"
pick /cx/lib/wine/x86_64-unix ""
is "Rosetta runner" "$T/game/runner/lib/wine/x86_64-unix/wine.app" "$game_app"

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
  runner_plist="$loader_work/runner.plist"
  mkdir -p "$loader_res"
  printf '%s' "${1:-plist}" > "$runner_plist"
  printf '%s' "${2:-icon}" > "$loader_res/game.icns"
  : > "$log"
  rc=0
  install_game_runner || rc=$?
  [ "$rc" -ne 0 ] || [ -d "$loader_work" ] || bad "runner leaves the stage for the tile" "present" "gone"
  rm -rf "$loader_work"
  return "$rc"
}
loader_app="$loader_root/Game.app"
mkdir -p "$loader_root/Old.app" "$loader_app"
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
is "old launcher gone, tile kept" "Game.app|" "$(apps)"
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
echo "== runner then tile =="
loader_work=$(mktemp -d "$loader_root/.build.XXXXXX")
loader_stage="$loader_work/new/Game.app"
loader_contents="$loader_stage/Contents"
loader_res="$loader_contents/Resources"
mkdir -p "$loader_res" "$loader_contents/MacOS" "$loader_root/Stale.app"
printf 'tile' > "$loader_contents/Info.plist"
printf 'icon' > "$loader_res/game.icns"
printf '#!/bin/sh\n' > "$loader_contents/MacOS/launcher"
chmod 755 "$loader_contents/MacOS/launcher"
runner_plist="$loader_work/runner.plist"
printf 'runner' > "$runner_plist"
: > "$log"
saved_support=$np_support
np_support="$T/no-support"
if ! { install_game_runner && install_bundle; }; then bad "runner then tile installs" "installed" "failed"; fi
np_support=$saved_support
is "tile and runner" "Game.app||tile|runner" "$(apps)|$(cat "$loader_app/Contents/Info.plist")|$(cat "$game_app/Contents/Info.plist")"
is "tile staging cleaned" "0" "$(leftover)"
launch_install=$(sed -n '/^elif install_game_runner; then$/,/^fi$/p' "$SRC")
[ -n "$launch_install" ] || { echo "FAIL: launch install code not found"; exit 1; }
: > "$log"
is "a failed tile still launches" "launched|game tile not installed" "$(
  set -e
  # shellcheck disable=SC2329
  install_game_runner() { :; }
  # shellcheck disable=SC2329
  install_bundle() { return 1; }
  eval "if false; then :
$launch_install"
  echo launched
)|$(cat "$log")"

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
is "Rosetta ntdll.so link" "so" "$(cat "$game_app/Contents/MacOS/ntdll.so")"
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

echo "== game tile =="
tile_mode=$(sed -n '/^  game-tile)$/,/^    ;;$/p' "$SRC" | sed '1d;$d')
[ -n "$tile_mode" ] || { echo "FAIL: game-tile mode not found"; exit 1; }
printf '#!/bin/sh\necho "${2##*/}" >> "%s/registered"\n' "$T" > "$T/lsregister"
printf '#!/bin/sh\n[ -e "%s/running-${2##*.}" ] && echo "ASN:0x0-0x1-\\"Game\\":"\nexit 0\n' "$T" > "$T/lsappinfo"
chmod 755 "$T/lsregister" "$T/lsappinfo"
game_tile() (
  macos=$1
  shift
  # shellcheck disable=SC2329
  sw_vers() { echo "$macos"; }
  lsregister="$T/lsregister"
  lsappinfo="$T/lsappinfo"
  : > "$T/registered"
  eval "$tile_mode"
)
registered() { paste -sd '|' "$T/registered"; }
runner_fixture() (
  game_name=$2 app_id=$3 icon_arg="  <key>CFBundleIconFile</key><string>game</string>"
  np_game_names
  r="$1/runner/lib/wine/x86_64-unix/wine.app/Contents"
  mkdir -p "$r/Resources" "$1/runner/lib/wine/aarch64-unix/wine.app/Contents"
  bundle_plist wine "com.notproton.launcher.$3" wine "$games_arg
  <key>LSUIElement</key><true/>" > "$r/Info.plist"
  printf 'game icon' > "$r/Resources/game.icns"
)
loader_fixture() (
  game_name=$2 icon_arg=""
  np_game_names
  mkdir -p "$1/$4.app/Contents/MacOS"
  bundle_plist "$game_name_xml" "com.notproton.launcher.$3" launcher "$games_arg" > "$1/$4.app/Contents/Info.plist"
  printf '#!/bin/sh\nexport WINELOADER="/w/wine"\nexec "/w/wine" "$@"\n' > "$1/$4.app/Contents/MacOS/launcher"
  chmod 755 "$1/$4.app/Contents/MacOS/launcher"
)
g="$T/tiles/1574480"
runner_fixture "$g" "Agent 64: Spies Never Die" 1574480
loader_fixture "$g" "Agent 64: Spies Never Die" 1574480 "Old Name"
game_tile 27.1 1574480 1574480 "$g"
r="$g/runner/lib/wine/x86_64-unix/wine.app/Contents/Info.plist" t="$g/Agent 64 Spies Never Die.app"
is "runner leaves the Games app" "-|true|wine|com.notproton.launcher.1574480" \
  "$(key "$r" LSApplicationCategoryType)|$(key "$r" LSSupportsGameMode)|$(key "$r" CFBundleExecutable)|$(key "$r" CFBundleIdentifier)"
is "tile identity" "com.notproton.game.1574480|launcher|Agent 64: Spies Never Die|public.app-category.games|game" \
  "$(key "$t/Contents/Info.plist" CFBundleIdentifier)|$(key "$t/Contents/Info.plist" CFBundleExecutable)|$(key "$t/Contents/Info.plist" CFBundleDisplayName)|$(key "$t/Contents/Info.plist" LSApplicationCategoryType)|$(key "$t/Contents/Info.plist" CFBundleIconFile)"
is "tile icon" "game icon" "$(cat "$t/Contents/Resources/game.icns")"
is "old bundles gone" "Agent 64 Spies Never Die.app" "$(find "$g" -maxdepth 1 -name '*.app' -exec basename {} \; | sort | paste -sd '|' -)"
is "runner and tile registered" "wine.app|Agent 64 Spies Never Die.app" "$(registered)"
(
  game_name="Agent 64: Spies Never Die" icon_arg="  <key>CFBundleIconFile</key><string>game</string>"
  np_game_names
  mkdir -p "$T/launch-tile"
  np_tile "$T/launch-tile" 1574480 "steam://rungameid/1574480"
)
if cmp -s "$T/launch-tile/Info.plist" "$t/Contents/Info.plist" &&
   cmp -s "$T/launch-tile/MacOS/launcher" "$t/Contents/MacOS/launcher"; then
  ok "same tile as a launch"
else
  bad "same tile as a launch" "identical" "different"
fi
game_tile 27.1 1574480 1574480 "$g"
is "second run changes nothing" "" "$(registered)"

g="$T/tiles/100"
runner_fixture "$g" "Old Game" 100
game_tile 15.7 100 100 "$g"
is "runner before macOS 26" "public.app-category.games|-" \
  "$(key "$g/runner/lib/wine/x86_64-unix/wine.app/Contents/Info.plist" LSApplicationCategoryType)|$(key "$g/runner/lib/wine/x86_64-unix/wine.app/Contents/Info.plist" LSSupportsGameMode)"
is "tile before macOS 26" "Old Game.app" "$(registered)"

g="$T/tiles/2898422707"
runner_fixture "$g" "My Shortcut" 2898422707
game_tile 27.1 2898422707 12448630736582344704 "$g"
sed -i '' "s|/usr/bin/open|$T/open|" "$g/My Shortcut.app/Contents/MacOS/launcher"
is "shortcut" "open steam://rungameid/12448630736582344704" "$("$g/My Shortcut.app/Contents/MacOS/launcher")"

g="$T/tiles/1422450"
loader_fixture "$g" Deadlock 1422450 Deadlock
game_tile 27.1 1422450 1422450 "$g"
is "own DLLs get the handoff" "$(printf '#!/bin/sh\n'; np_handoff steam://rungameid/1422450; printf 'export WINELOADER="/w/wine"\nexec "/w/wine" "$@"\n')" \
  "$(cat "$g/Deadlock.app/Contents/MacOS/launcher")"
is "own DLLs registered" "Deadlock.app" "$(registered)"
game_tile 27.1 1422450 1422450 "$g"
is "handoff only once" "1|" "$(grep -c rungameid "$g/Deadlock.app/Contents/MacOS/launcher")|$(registered)"

g="$T/tiles/400"
runner_fixture "$g" Running 400
: > "$T/running-400"
game_tile 27.1 400 400 "$g"
rm "$T/running-400"
is "running game skipped" "public.app-category.games||" \
  "$(key "$g/runner/lib/wine/x86_64-unix/wine.app/Contents/Info.plist" LSApplicationCategoryType)|$(find "$g" -maxdepth 1 -name '*.app')|$(registered)"
game_tile 27.1 400 400 "$g"
is "after it quits" "-|Running.app" \
  "$(key "$g/runner/lib/wine/x86_64-unix/wine.app/Contents/Info.plist" LSApplicationCategoryType)|$(find "$g" -maxdepth 1 -name '*.app' -exec basename {} \;)"

g="$T/tiles/300"
runner_fixture "$g" Locked 300
(exec 7>> "$g/.lock"; /usr/bin/lockf -s -t 0 7; game_tile 27.1 300 300 "$g")
is "starting game skipped" "public.app-category.games|" \
  "$(key "$g/runner/lib/wine/x86_64-unix/wine.app/Contents/Info.plist" LSApplicationCategoryType)|$(find "$g" -maxdepth 1 -name '*.app')"
for args in "abc 1 /x" "1 abc /x" "1 1 relative"; do
  # shellcheck disable=SC2086
  if (set -- $args; game_tile 27.1 "$@") 2>/dev/null; then bad "bad arguments [$args]" "exit 1" "exit 0"; else ok "bad arguments [$args]"; fi
done

echo "== game untile =="
untile_mode=$(sed -n '/^  game-untile)$/,/^    ;;$/p' "$SRC" | sed '1d;$d')
[ -n "$untile_mode" ] || { echo "FAIL: game-untile mode not found"; exit 1; }
game_untile() (
  macos=$1
  shift
  # shellcheck disable=SC2329
  sw_vers() { echo "$macos"; }
  lsregister="$T/lsregister"
  lsappinfo="$T/lsappinfo"
  : > "$T/registered"
  eval "$untile_mode"
)
category() { key "$1/Contents/Info.plist" LSApplicationCategoryType; }
kept() (cd "$1" && find . -type f ! -name Info.plist ! -name .lock | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done)

g="$T/untile/2062120"
runner_fixture "$g" "Resident Evil Village" 2062120
loader_fixture "$g" "Resident Evil Village" 2062120 "Resident Evil Village"
printf 'wine log' > "$g/notproton-wine.log"
printf 'ico' > "$g/clienticon-abc.ico"
printf 'icns' > "$g/game.icns"
before=$(kept "$g")
game_untile 27.1 2062120 "$g"
rw="$g/runner/lib/wine/x86_64-unix/wine.app"
is "gone from the Games app" "-|-" "$(category "$rw")|$(category "$g/Resident Evil Village.app")"
is "both registered" "wine.app|Resident Evil Village.app" "$(registered)"
is "nothing else touched" "$before" "$(kept "$g")"
is "identity kept" "com.notproton.launcher.2062120|wine|com.notproton.launcher.2062120|launcher" \
  "$(key "$rw/Contents/Info.plist" CFBundleIdentifier)|$(key "$rw/Contents/Info.plist" CFBundleExecutable)|$(key "$g/Resident Evil Village.app/Contents/Info.plist" CFBundleIdentifier)|$(key "$g/Resident Evil Village.app/Contents/Info.plist" CFBundleExecutable)"
game_untile 27.1 2062120 "$g"
is "second untile changes nothing" "" "$(registered)"

game_tile 27.1 2062120 2062120 "$g"
t="$g/Resident Evil Village.app"
is "reinstalled game is back" "public.app-category.games|com.notproton.game.2062120|true" \
  "$(category "$t")|$(key "$t/Contents/Info.plist" CFBundleIdentifier)|$(key "$rw/Contents/Info.plist" LSSupportsGameMode)"
game_untile 27.1 2062120 "$g"
is "tile leaves too" "-" "$(category "$t")"
game_tile 27.1 2062120 2062120 "$g"
is "tile comes back" "public.app-category.games" "$(category "$t")"

g="$T/untile/1422450"
loader_fixture "$g" Deadlock 1422450 Deadlock
game_tile 27.1 1422450 1422450 "$g"
game_untile 27.1 1422450 "$g"
is "own DLLs leave" "-|1" "$(category "$g/Deadlock.app")|$(grep -c rungameid "$g/Deadlock.app/Contents/MacOS/launcher")"
game_tile 27.1 1422450 1422450 "$g"
is "own DLLs come back" "public.app-category.games|1|Deadlock.app" \
  "$(category "$g/Deadlock.app")|$(grep -c rungameid "$g/Deadlock.app/Contents/MacOS/launcher")|$(registered)"

g="$T/untile/700"
runner_fixture "$g" Older 700
game_untile 15.7 700 "$g"
is "untouched before macOS 26" "public.app-category.games|" "$(category "$g/runner/lib/wine/x86_64-unix/wine.app")|$(registered)"
(exec 7>> "$g/.lock"; /usr/bin/lockf -s -t 0 7; game_untile 27.1 700 "$g")
is "starting game untouched" "public.app-category.games|" "$(category "$g/runner/lib/wine/x86_64-unix/wine.app")|$(registered)"
: > "$T/running-700"
game_untile 27.1 700 "$g"
rm "$T/running-700"
is "running game untouched" "public.app-category.games|" "$(category "$g/runner/lib/wine/x86_64-unix/wine.app")|$(registered)"
loader_fixture "$g" Other 701 Other
game_untile 27.1 700 "$g"
is "other game's bundle untouched" "public.app-category.games" "$(category "$g/Other.app")"
for args in "abc /x" "700 relative" "700 $T/untile/missing"; do
  # shellcheck disable=SC2086
  if (set -- $args; game_untile 27.1 "$@") 2>/dev/null; then bad "untile bad arguments [$args]" "exit 1" "exit 0"; else ok "untile bad arguments [$args]"; fi
done

[ "$fails" -eq 0 ] || { echo "launchercheck: $fails failed"; exit 1; }
echo "launchercheck: all passed"
