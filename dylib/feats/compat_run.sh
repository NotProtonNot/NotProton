#!/bin/sh
# notproton CrossOver compatibility tool shim
set -e

verb="$1"
shift || true

# hook_launch.c passes the launch options through a shell before this script runs, matching
# Linux Steam. A NAME=value option placed ahead of %command% is an environment variable,
# and anything after %command% is a launch argument passed to the game.
launch_args="$*"

case "$verb" in
  getcompatpath)
    printf '%s\n' "$STEAM_COMPAT_DATA_PATH"
    exit 0
    ;;
esac

np_support="$HOME/Library/Application Support/notproton"
iconmaker="$np_support/iconmaker"

find_client_root() {
  client_root="$1"
  while [ -n "$client_root" ] && [ "$client_root" != "/" ] && [ ! -d "$client_root/appcache" ]; do
    client_root=$(dirname "$client_root")
  done
}

read_app_meta() {
  appinfo_tool="$np_support/appinfo"
  appinfo_vdf="$client_root/appcache/appinfo.vdf"
  meta_name=""
  meta_icon=""
  meta_clienticon=""
  if [ -x "$appinfo_tool" ] && [ -f "$appinfo_vdf" ]; then
    meta=$("$appinfo_tool" "$appinfo_vdf" "$app_id" 2>> "$log") || meta=""
    meta_name=$(printf '%s\n' "$meta" | sed -n 's/^name=//p')
    meta_icon=$(printf '%s\n' "$meta" | sed -n 's/^icon=//p')
    meta_clienticon=$(printf '%s\n' "$meta" | sed -n 's/^clienticon=//p')
    case "$meta_icon" in *[!0-9a-f]*) meta_icon="" ;; esac
    case "$meta_clienticon" in *[!0-9a-f]*) meta_clienticon="" ;; esac
  fi
}

resolve_icon() {
  set +e
  art_dir="$client_root/appcache/librarycache/$app_id"
  art=""
  ico=""
  if [ -n "$meta_clienticon" ]; then
    ico="$icon_root/clienticon-$meta_clienticon.ico"
    absent="$icon_root/clienticon-$meta_clienticon.absent"
    failed="$icon_root/clienticon-$meta_clienticon.failed"
    find "$icon_root" -maxdepth 1 -name 'clienticon-*'   ! -name "clienticon-$meta_clienticon.*" -delete 2>/dev/null || true
    find "$absent" -mtime +14 -delete 2>/dev/null || true
    find "$failed" -mmin +60 -delete 2>/dev/null || true
    if [ ! -s "$ico" ] && [ ! -f "$absent" ] && [ ! -f "$failed" ]; then
      url="https://shared.fastly.steamstatic.com/community_assets/images/apps/$app_id/$meta_clienticon.ico"
      code=$(curl -fsL --connect-timeout 5 --max-time 20 -w '%{http_code}' -o "$ico.new" "$url" 2>>"$log")
      magic=$(od -An -tx1 -N4 "$ico.new" 2>/dev/null | tr -d ' \n')
      if [ "$magic" = "00000100" ]; then
        mv -f "$ico.new" "$ico"
        echo "fetched client icon $meta_clienticon" >> "$log" 2>&1 || true
      else
        rm -f "$ico.new"
        if [ "$code" = "404" ]; then
          : > "$absent"
          echo "no client icon published for $meta_clienticon" >> "$log" 2>&1 || true
        else
          : > "$failed"
          echo "client icon fetch for $meta_clienticon failed (http ${code:-none}), will retry in an hour" >> "$log" 2>&1 || true
        fi
      fi
    fi
    [ -s "$ico" ] && art="$ico"
  fi
  if [ -z "$art" ] && [ -n "$meta_icon" ] && [ -f "$art_dir/$meta_icon.jpg" ]; then
    art="$art_dir/$meta_icon.jpg"
  fi
  if [ -z "$art" ]; then
    art=$(find "$art_dir" -maxdepth 1 -type f -name '*.jpg' 2>/dev/null |   grep -E '/[0-9a-f]{40}\.jpg$' | head -1)
  fi
  # Capsule art (horrible) fallback if no icon at all exists...
  if [ -z "$art" ]; then
    for name in library_600x900.jpg header.jpg; do
      found=$(find "$art_dir" -name "$name" 2>/dev/null | head -1)
      [ -n "$found" ] && { art="$found"; break; }
    done
  fi
  # non-Steam shortcuts have no art, so (as a temporary measure while I think of
  # better ways to solve for this) let's use the icon in the EXE itself instead.
  if [ -z "$art" ] && [ -f "$target" ]; then
    case "$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')" in
      *.exe) art="$target" ;;
    esac
  fi
  icon_source=""
  if [ -n "$art" ]; then
    icon_source="$art $(stat -f %m "$art" 2>/dev/null || echo 0)"
  fi
  icon_cache="$icon_root/game.icns"
  icon_status=1
  if [ -n "$art" ] && [ -s "$icon_cache" ] &&   [ "$(cat "$icon_root/notproton-icon.source" 2>/dev/null)" =   "$icon_source" ]; then
    icon_status=0
    echo "icon reused from $art" >> "$log" 2>&1 || true
  elif [ -n "$art" ] && [ -x "$iconmaker" ]; then
    if "$iconmaker" "$art" "$icon_cache" >> "$log" 2>&1; then
      icon_status=0
      printf '%s\n' "$icon_source" > "$icon_root/notproton-icon.source"
      echo "icon built from $art" >> "$log" 2>&1 || true
    elif [ "$art" = "$ico" ]; then
      # A cached .ico that iconmaker rejects is corrupt and passes the size
      # guard on every launch, so drop it to force a clean fetch next time.
      rm -f "$ico"
      echo "discarded unreadable client icon $meta_clienticon" >> "$log" 2>&1 || true
    fi
  fi
  set -e
  return $icon_status
}

case "$verb" in
  shortcut-icons)
    app_id="$1"
    case "$app_id" in ''|0|*[!0-9]*) exit 1 ;; esac
    case "$2" in /*) ;; *) exit 1 ;; esac
    find_client_root "$2"
    icon_root="$np_support/shortcut-icons/$app_id"
    mkdir -p "$icon_root"
    log="$icon_root/icon.log"
    : > "$log"
    target=""
    read_app_meta
    resolve_icon && "$iconmaker" --shortcuts "$app_id" "$icon_cache" "$2/steam.icns" >> "$log" 2>&1 || true
    exit 0
    ;;
esac

# cxcompatdb resolves its database through CX_HOME and logs an error for
# every module loaded without it :(
export CX_HOME="$HOME/Library/Application Support/CrossOver"
np_flavor=""
np_build=""
CDPATH=''
np_tool_dir=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || np_tool_dir=""
if [ -n "$np_tool_dir" ] && [ -r "$np_tool_dir/flavor" ]; then
  read -r np_flavor < "$np_tool_dir/flavor" || np_flavor=""
fi
if [ -n "$np_tool_dir" ] && [ -r "$np_tool_dir/build" ]; then
  read -r np_build < "$np_tool_dir/build" || np_build=""
fi
case "$np_build" in *[!A-Za-z0-9.-]*) np_build="" ;; esac
np_display=$(sed -n 's/.*"display_name"[[:space:]]*"\(.*\)".*/\1/p' \
  "$np_tool_dir/compatibilitytool.vdf" 2>/dev/null | head -1) || np_display=""
[ -n "$np_display" ] || np_display="CrossOver build ${np_build:-unknown}"
CX_ROOT="$np_support/runners/crossover-$np_build/CrossOver"
export CX_ROOT
# CrossOver initializes Rosetta's Windows thread-state support even without D3DMetal.
if [ -f "$CX_ROOT/lib64/apple_gptk/external/libd3dshared.dylib" ]; then
  export CX_APPLEGPTK_LIBD3DSHARED_PATH="$CX_ROOT/lib64/apple_gptk/external/libd3dshared.dylib"
fi

wine_unix="$CX_ROOT/lib/wine/aarch64-unix"
WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
WINESERVER="$CX_ROOT/bin/wineserver-arm64"
if [ "$np_flavor" = rosetta ] || [ ! -x "$WINELOADER" ] || [ ! -x "$WINESERVER" ]; then
  wine_unix="$CX_ROOT/lib/wine/x86_64-unix"
  WINELOADER="$wine_unix/wine"
  WINESERVER="$CX_ROOT/bin/wineserver"
  [ -x "$WINESERVER" ] || WINESERVER="$CX_ROOT/bin/wineserver-x86"
fi
export WINELOADER WINESERVER

np_from_defaults() {
  case " $np_defaulted " in *" $1="*) return 0 ;; esac
  return 1
}
np_defaulted=""
case "${np_flavor-}" in
  fex) np_defaults_runner=fex ;;
  rosetta) np_defaults_runner=rosetta ;;
  *) np_defaults_runner=rosetta; [ "${wine_unix##*/}" != aarch64-unix ] || np_defaults_runner=fex ;;
esac
np_defaults_file="$np_support/defaults-$np_defaults_runner"
if [ -n "${np_build-}" ] && [ -f "$np_support/defaults-override-$np_build-$np_defaults_runner" ]; then
  np_defaults_file="$np_support/defaults-override-$np_build-$np_defaults_runner"
fi
if [ "$verb" = waitforexitandrun ] && [ -f "$np_defaults_file" ] && [ -r "$np_defaults_file" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$line" in
      CX_GRAPHICS_BACKEND=dxmt | CX_GRAPHICS_BACKEND=dxvk | CX_GRAPHICS_BACKEND=wined3d) ;;
      CX_GRAPHICS_BACKEND=d3dmetal | D3DM_ENABLE_METALFX=[01] | ROSETTA_ADVERTISE_AVX=[01])
        [ "${wine_unix##*/}" != aarch64-unix ] || continue ;;
      FEX_X87REDUCEDPRECISION=[01])
        [ "${wine_unix##*/}" = aarch64-unix ] || continue ;;
      MTL_HUD_ENABLED=[01] | DXMT_ENABLE_NVEXT=[01] | DXMT_METALFX_SPATIAL_SWAPCHAIN=[01] | \
      WINEMSYNC=[01] | NOTPROTON_RETINA=[01] | NOTPROTON_RAW_CONTROLLERS=[01] | NOTPROTON_DISABLE_HIDRAW=[01]) ;;
      DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=*)
        case "${value#*=}" in 1.5 | 1.72 | 2.0 | 3.0) ;; *) continue ;; esac
        if printf '%s' "${DXMT_CONFIG-}" | tr ';' '\n' \
          | grep -q '^[[:space:]]*d3d11\.metalSpatialUpscaleFactor[[:space:]]*='; then
          continue
        fi
        export DXMT_CONFIG="${DXMT_CONFIG:+$DXMT_CONFIG;}$value"
        np_defaulted="$np_defaulted${np_defaulted:+ }$line"
        continue ;;
      *) continue ;;
    esac
    eval "[ -z \"\${$key+x}\" ]" || continue
    export "${line?}"
    np_defaulted="$np_defaulted${np_defaulted:+ }$line"
  done < "$np_defaults_file"
fi
[ "${CX_GRAPHICS_BACKEND-}" != auto ] || unset -v CX_GRAPHICS_BACKEND

np_dropped=""
if [ "${wine_unix##*/}" = aarch64-unix ]; then
  if [ "${CX_GRAPHICS_BACKEND:-}" = d3dmetal ]; then
    unset -v CX_GRAPHICS_BACKEND
    np_dropped="CX_GRAPHICS_BACKEND=d3dmetal"
  fi
  for name in $(env | LC_ALL=C sed -nE 's/^(D3DM_[A-Z0-9_]*|ROSETTA_ADVERTISE_AVX)=.*/\1/p' | LC_ALL=C sort); do
    unset -v "$name"
    np_dropped="$np_dropped${np_dropped:+ }$name"
  done
  fex_from=environment
  [ -n "${FEX_X87REDUCEDPRECISION+x}" ] || fex_from=default
  if np_from_defaults FEX_X87REDUCEDPRECISION; then fex_from=${np_defaults_file##*/}; fi
  export FEX_X87REDUCEDPRECISION="${FEX_X87REDUCEDPRECISION-1}"
else
  avx_from=environment
  [ -n "$ROSETTA_ADVERTISE_AVX" ] || avx_from=default
  if np_from_defaults ROSETTA_ADVERTISE_AVX; then avx_from=${np_defaults_file##*/}; fi
  export ROSETTA_ADVERTISE_AVX="${ROSETTA_ADVERTISE_AVX:-1}"
fi

# Keeps Wine from inheriting the prefix and template locks (fd 8 and 9).
without_lock_fds() {
  "$@" 8>&- 9>&-
}

# If two WINEDLLPATH directories have the same DLL, Wine uses the one listed first.
export WINEDLLPATH="$CX_ROOT/lib/wine/x86_64-windows:$wine_unix${WINEDLLPATH:+:$WINEDLLPATH}"
export PATH="$CX_ROOT/bin:$PATH"

if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
  log="$STEAM_COMPAT_DATA_PATH/notproton-run.log"
else
  log=/dev/null
fi
[ "$(stat -f %z "$log" 2>/dev/null || echo 0)" -gt 262144 ] \
  && : > "$log" || true
{
  echo "=== notproton run $(date) ==="
  echo "verb=$verb"
  echo "args:"; for a in "$@"; do printf '  [%s]\n' "$a"; done
  echo "cwd=$(pwd)"
  echo "STEAM_COMPAT_DATA_PATH=$STEAM_COMPAT_DATA_PATH"
  echo "STEAM_COMPAT_INSTALL_PATH=$STEAM_COMPAT_INSTALL_PATH"
  echo "STEAM_COMPAT_APP_ID=$STEAM_COMPAT_APP_ID"
  echo "-- steam env passed through --"
  env | grep -iE '^(Steam|SDL_)' | sort
  [ -z "$np_defaulted" ] || echo "from ${np_defaults_file##*/}: $np_defaulted"
  [ -z "$np_dropped" ] || echo "ignored on arm64 Wine: $np_dropped"
} >> "$log" 2>&1 || true

stage_step="startup"
# shellcheck disable=SC2329 # the trap below invokes this
report_early_exit() {
  status=$?
  [ "$status" = 0 ] && return 0
  echo "=== aborted during $stage_step (exit $status) before launch ===" \
    >> "$log" 2>&1 || true
}
trap report_early_exit EXIT

while :; do
  case "$STEAM_COMPAT_INSTALL_PATH" in
    ?*/) STEAM_COMPAT_INSTALL_PATH="${STEAM_COMPAT_INSTALL_PATH%/}" ;;
    *) break ;;
  esac
done
export STEAM_COMPAT_INSTALL_PATH

app_id="$STEAM_COMPAT_APP_ID"
case "$app_id" in ''|0) app_id="$SteamAppId" ;; esac
case "$app_id" in ''|0) app_id=$(basename "$STEAM_COMPAT_DATA_PATH" 2>/dev/null) ;; esac
case "$app_id" in ''|*[!0-9]*) app_id=0 ;; esac
echo "app_id=$app_id (STEAM_COMPAT_APP_ID=$STEAM_COMPAT_APP_ID)" >> "$log" 2>&1 || true

# Steam gives every non-Steam shortcut a game ID ending in 0x02000000.
shortcut_game_id() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 20 ] || return 1
  high=0
  low="$1"
  if [ "${#1}" -gt 10 ]; then
    high="${1%??????????}"
    low="${1#"$high"}"
  fi
  high="${high#"${high%%[!0]*}"}"
  low="${low#"${low%%[!0]*}"}"
  [ $(( (${high:-0} % 4294967296 * 1410065408 + ${low:-0}) % 4294967296 )) = 33554432 ]
}

# Steam does not set SteamAppId or SteamGameId for helpers like the install-script
# evaluator. If they are set, SteamAPI_Init registers the helper as the running game so the
# real launch fails with AppError_16. Not applicable to non-Steam shortcuts, which come in
# as waitforexitandrun.
case "$verb" in
  waitforexitandrun)
    # Some games are poorly engineered and treat a shortcut's SteamAppID as if it were a real
    # Steam appid. Those games immediately fail Steam ownership checks rather than looking
    # inward and realizing that the actual game build that is running is a version that was
    # sold outside of Steam and that the applicable ownership checks should be performed (not
    # the Steam ones). Rockstar: do better?
    if shortcut_game_id "$SteamGameId"; then
      unset SteamAppId
    else
      [ -n "$SteamAppId" ] || export SteamAppId="$app_id"
    fi
    [ -n "$SteamGameId" ] || export SteamGameId="$app_id"
    ;;
esac

prefix_machine() {
  dll="$WINEPREFIX/drive_c/windows/system32/ntdll.dll"
  [ -f "$dll" ] || return 1
  off=$(od -A n -t u4 -j 60 -N 4 "$dll" 2>/dev/null | tr -d ' ')
  case "$off" in ''|*[!0-9]*) return 1 ;; esac
  sig=$(od -A n -t x1 -j "$off" -N 4 "$dll" 2>/dev/null | tr -d ' \n')
  [ "$sig" = 50450000 ] || return 1
  od -A n -t x2 -j "$((off + 4))" -N 2 "$dll" 2>/dev/null | tr -d ' \n'
}

tool_name() {
  case "$1" in
    aa64) printf 'FEX' ;;
    8664) printf 'Rosetta' ;;
    *) printf '32-bit' ;;
  esac
}

# CrossOver's previews are versioned by date, which reads as a release without the word.
preview_name() {
  case "$1" in
    # The date keeps its spaces and the arch its hyphen, but the dialog may only wrap
    # before the version, never inside it.
    "CrossOver 20"[0-9][0-9]" "*)
      printf 'CrossOver Preview %s' "$(printf '%s' "${1#CrossOver }" \
        | sed "s/ /$(printf '\302\240')/g; s/-/$(printf '\342\200\221')/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Tool names already end in the arch, which the sentence names on its own.
running_name() {
  run_name=$1
  case "$run_name" in *" - Rosetta" | *" - FEX") run_name=${run_name% - *} ;; esac
  printf '%s, running through %s' "$(preview_name "$run_name")" "$2"
}

# Steam passes "run" for helpers such as install scripts, which get no dialog.
show_alert() {
  [ "$verb" != run ] || return 0
  exec 8>&- 9>&-
  osascript >/dev/null 2>&1 <<APPLESCRIPT || true
display alert "$1" message "$2" as critical
APPLESCRIPT
}

# A quote or backslash in the text would end the AppleScript string early.
alert_safe() {
  # shellcheck disable=SC1003 # the pair deletes a literal backslash, not a quote
  printf '%s' "$1" | tr -d '"\\'
}

# The log path reaches AppleScript as an argument, so a quote in it cannot end a string.
show_rebuild_failure() {
  [ "$verb" != run ] || return 0
  exec 8>&- 9>&-
  answer=$(osascript - "$log" <<'APPLESCRIPT'
on run argv
  set answer to display alert "Prefix rebuild failed!" message ("Check notproton-run.log at " & (item 1 of argv) & ".") as critical buttons {"Open Log", "OK"} default button "OK"
  return button returned of answer
end run
APPLESCRIPT
  ) || answer=""
  [ "$answer" != "Open Log" ] || { [ -f "$log" ] && [ ! -L "$log" ] && open -t "$log" >/dev/null 2>&1; } || true
}

# Steam shows the game as running while this waits, and Stop kills the script's process
# group and children. A rebuild killed between its two renames leaves no pfx at all, so the
# app runs outside both: the inner subshell is reparented to launchd and the app calls
# setsid. The script only waits for the exit status the subshell leaves behind.
run_rebuild() {
  rebuild_exit="$STEAM_COMPAT_DATA_PATH/notproton-rebuild-exit"
  rebuild_lock="$STEAM_COMPAT_DATA_PATH/.notproton-rebuild.lock"
  rm -f "$rebuild_exit"
  (
    (
      env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        NOTPROTON_REBUILD_WINDOW=1 \
        "$1" --rebuild-prefix "$STEAM_COMPAT_DATA_PATH" "${np_tool_dir##*/}" \
        "$np_build" "$np_flavor" "$2" >> "$log" 2>&1 < /dev/null
      echo "$?" > "$rebuild_exit.$$" && mv -f "$rebuild_exit.$$" "$rebuild_exit"
    ) &
  )
  waited=0
  while [ ! -f "$rebuild_exit" ]; do
    sleep 1
    waited=$((waited + 1))
    # Nothing holds the lock once the app is gone. The grace covers its startup.
    if [ "$waited" -gt 30 ] && /usr/bin/lockf -s -t 0 "$rebuild_lock" true 2>/dev/null; then
      sleep 2
      [ -f "$rebuild_exit" ] || return 1
    fi
  done
  read -r rebuild_status_code < "$rebuild_exit" || rebuild_status_code=1
  rm -f "$rebuild_exit"
  [ "$rebuild_status_code" = 0 ]
}

# $1 is the title, $2 the message. With $3, that button skips the rebuild and the launch goes on.
rebuild_prefix() {
  # Install-script helpers must never prompt or rebuild behind the player's back.
  [ "$verb" != run ] || { [ -n "$3" ] && return 0; exit 1; }
  [ "${np_rebuilt:-0}" != 1 ] || {
    show_rebuild_failure
    exit 1
  }
  exec 8>&- 9>&-
  # AppleScript run from a shell has no icon of its own, so caution comes badged with a folder.
  icon=$(cat "$np_support/app-executable" 2>/dev/null) || icon=""
  icon="${icon%/Contents/MacOS/*}/Contents/Resources/NotProton.icns"
  [ -f "$icon" ] || icon=""
  choice=$(osascript - "$1" "$2" "${3:-Cancel}" "$icon" <<'APPLESCRIPT'
on run argv
  set choices to {item 3 of argv, "Rebuild Prefix", "Backup & Rebuild Prefix"}
  if item 4 of argv is "" then
    set answer to display dialog (item 2 of argv) with title (item 1 of argv) buttons choices default button "Backup & Rebuild Prefix" cancel button (item 3 of argv) with icon caution
  else
    set answer to display dialog (item 2 of argv) with title (item 1 of argv) buttons choices default button "Backup & Rebuild Prefix" cancel button (item 3 of argv) with icon ((POSIX file (item 4 of argv)) as alias)
  end if
  return button returned of answer
end run
APPLESCRIPT
  ) || choice=""
  case "$choice" in
    'Backup & Rebuild Prefix') backup=keep-backup ;;
    'Rebuild Prefix') backup=discard-backup ;;
    *)
      [ -n "$3" ] || exit 1
      prepare_prefix_directory || exit 1
      return 0
      ;;
  esac
  executable=$(cat "$np_support/app-executable" 2>/dev/null) || executable=""
  if [ ! -x "$executable" ]; then
    show_alert "Couldn't find the NotProton app" "The prefix wasn't rebuilt and the game wasn't launched, because the NotProton app was moved or deleted since it was installed, or was installed from a disk image or Downloads. Move NotProton to Applications, open it and click Install again, then launch the game."
    exit 1
  fi
  if ! run_rebuild "$executable" "$backup"; then
    # This dialog says it failed, so the page should not say it again later. A refusal
    # because another rebuild runs left that rebuild's progress, which stays.
    rebuild_status="$STEAM_COMPAT_DATA_PATH/notproton-rebuild"
    [ "$(head -n 1 "$rebuild_status" 2>/dev/null)" != failed ] || rm -f "$rebuild_status"
    show_rebuild_failure
    exit 1
  fi
  rm -f "$STEAM_COMPAT_DATA_PATH/notproton-switch" "$STEAM_COMPAT_DATA_PATH/notproton-rebuild"
  # A competing launch or rebuild may have run while the dialog was open.
  # Retake the normal launch lock and check both mismatches before touching Wine.
  if ! prepare_prefix_directory; then
    show_alert "Prefix rebuilt" "Another launch is using this prefix. Wait for it to finish, then launch the game again."
    exit 1
  fi
  np_rebuilt=1
  note_other_build
  refuse_foreign_prefix
}

refuse_foreign_prefix() {
  case "${wine_unix##*/}" in
    aarch64-unix) want=aa64 ;;
    *) want=8664 ;;
  esac
  have=$(prefix_machine) || return 0
  [ "$have" = "$want" ] && return 0
  echo "=== prefix ntdll is $have and this compatibility tool wants $want, rebuild the prefix in NotProton ===" >> "$log" 2>&1 || true
  had_tool=$(tool_name "$have")
  want_tool=$(tool_name "$want")
  explanation="$had_tool prefixes cannot be used with versions of CrossOver that run through $want_tool unless they are rebuilt."
  # note_other_build read the build that set up the prefix.
  case "$have:$had_display" in
    aa64:?* | 8664:?*)
      explanation="This game's prefix was last used by $(running_name "$had_display" "$had_tool"). $explanation"
      ;;
  esac
  rebuild_prefix "This game needs its prefix rebuilt" "$explanation

Do you want to rebuild the prefix for $(running_name "$np_display" "$want_tool")? Your save games will be preserved and not lost."
}

last_wine_build() {
  updated_file="$STEAM_COMPAT_DATA_PATH/pfx/.update-timestamp"
  [ -r "$updated_file" ] || return 0
  read -r updated _ < "$updated_file" || true
  # Wine ends the line with CRLF.
  updated=${updated%"$(printf '\r')"}
  case "$updated" in '' | *[!0-9]*) return 0 ;; esac
  [ "$updated" = "$(stat -f %m "$CX_ROOT/share/wine/wine.inf" 2>/dev/null)" ] && return 0
  had_build=other
  had_display="another version of CrossOver"
  for inf in "$np_support"/runners/crossover-*/CrossOver/share/wine/wine.inf; do
    [ "$(stat -f %m "$inf" 2>/dev/null)" = "$updated" ] || continue
    if [ "$had_build" != other ]; then
      had_build=other
      had_display="another version of CrossOver"
      break
    fi
    had_build=${inf#"$np_support/runners/crossover-"}
    had_build=${had_build%%/*}
    had_display=$(awk -F '\t' -v b="$had_build" '$2 == b { print $4; exit }' \
      "$np_support/tools" 2>/dev/null) || had_display=""
  done
}

# A prefix from another build of the same arch runs as is, in either direction. Its
# .update-timestamp no longer matches wine.inf, and Wine reruns wine.inf on first start,
# which replaces builtin DLLs and keeps native ones.
note_other_build() {
  record="$STEAM_COMPAT_DATA_PATH/notproton-build"
  had_build=""
  had_display=""
  if [ -r "$record" ]; then
    {
      read -r had_build || true
      read -r had_display || true
    } < "$record"
  else
    last_wine_build
  fi
  if [ -n "$had_build" ] && [ "$had_build" != "$np_build" ]; then
    echo "=== prefix was last run by build $had_build (${had_display:-unknown}), Wine updates it for $np_build ===" >> "$log" 2>&1 || true
    case "${wine_unix##*/}:$(prefix_machine)" in
      aarch64-unix:8664 | aarch64-unix:014c | x86_64-unix:aa64 | x86_64-unix:014c) return 0 ;;
    esac
    switch="$STEAM_COMPAT_DATA_PATH/notproton-switch"
    rm -f "$switch"
    # Only a build the game is known to have run on can be blamed for a crash after the switch.
    if [ "$(head -1 "$STEAM_COMPAT_DATA_PATH/notproton-healthy" 2>/dev/null)" = "$had_build" ]; then
      printf '%s\n%s\n0\n' "$had_build" "${had_display:-CrossOver build $had_build}" > "$switch" 2>/dev/null || true
    fi
  fi
}

# Healthy is a session Steam did not cut short or that lasted, with no Wine crash. Failed is a
# crash within the first minute. Anything else says nothing about the build.
session_health() {
  crashed=0
  grep -q -E 'Unhandled (page fault|exception)|err:module:import_dll' "$1" 2>/dev/null && crashed=1
  if [ "$crashed" = 1 ] && [ "$2" -lt 60 ] && [ "$3" != 1 ]; then
    echo failed
  elif [ "$crashed" = 0 ] && { [ "$3" != 1 ] || [ "$2" -ge 60 ]; }; then
    echo healthy
  else
    echo unknown
  fi
}

set_switch_state() {
  if ! { sed -n 1,2p "$switch" && printf '%s\n' "$1"; } > "$switch.$$" \
    || ! mv -f "$switch.$$" "$switch"; then
    rm -f "$switch.$$"
  fi
}

# The switch record is old build, its name, then the healthy sessions since or "failed".
# Two healthy sessions clear it.
record_session() {
  switch="$STEAM_COMPAT_DATA_PATH/notproton-switch"
  health=$(session_health "$1" "$2" "$3")
  echo "=== session health: $health after $2s ===" >> "$log" 2>&1 || true
  case "$health" in
    healthy)
      printf '%s\n' "$np_build" > "$STEAM_COMPAT_DATA_PATH/notproton-healthy" 2>/dev/null || true
      [ -f "$switch" ] || return 0
      count=$(sed -n 3p "$switch")
      case "$count" in
        0) set_switch_state 1 ;;
        *) rm -f "$switch" ;;
      esac
      ;;
    failed)
      [ -f "$switch" ] || return 0
      set_switch_state failed
      ;;
  esac
}

# Asked once per switch, at the next launch after the crash.
offer_switch_rebuild() {
  switch="$STEAM_COMPAT_DATA_PATH/notproton-switch"
  [ "$(sed -n 3p "$switch" 2>/dev/null)" = failed ] || return 0
  [ "$verb" != run ] || return 0
  old_display=$(sed -n 2p "$switch")
  case "${wine_unix##*/}" in
    aarch64-unix) now_arch=aa64 ;;
    *) now_arch=8664 ;;
  esac
  rm -f "$switch"
  echo "=== last session crashed after switching from $old_display, offering a rebuild ===" >> "$log" 2>&1 || true
  rebuild_prefix "This game may need its prefix rebuilt" \
    "Something appears to have gone wrong the last time you ran this game! Rebuilding the prefix may fix it.

Rebuild your prefix for $(running_name "$np_display" "$(tool_name "$now_arch")")? Your save games will be preserved and not lost." \
    "Launch Without Rebuilding"
}

claim_prefix() {
  [ -r "$STEAM_COMPAT_DATA_PATH/notproton-build" ] \
    || echo "=== prefix claimed by build $np_build ===" >> "$log" 2>&1 || true
  printf '%s\n%s\n' "$np_build" "$np_display" > "$STEAM_COMPAT_DATA_PATH/notproton-build" 2>/dev/null \
    || echo "=== could not record build $np_build in the prefix ===" >> "$log" 2>&1 || true
}
# Steam cloud related
merge_user_dir() {
  src=$1
  dst=$2
  failed=
  set -- ""
  while [ "$#" -gt 0 ]; do
    rest=$1
    shift
    src_dir="$src$rest"
    dst_dir="$dst$rest"
    if [ ! -r "$src_dir" ] || [ ! -x "$src_dir" ]; then failed=1; continue; fi
    if [ -L "$dst_dir" ]; then failed=1; continue; fi
    probe=$dst_dir
    through=
    while [ -n "$probe" ] && [ "$probe" != "$dst" ]; do
      if [ -L "$probe" ]; then through=1; break; fi
      probe=${probe%/*}
    done
    if [ -n "$through" ]; then
      echo "=== $rest is held by a link, merge refused ===" >> "$log" 2>&1 || true
      failed=1
      continue
    fi
    if [ -e "$dst_dir" ] && [ ! -d "$dst_dir" ]; then
      failed=1
      continue
    fi
    if ! mkdir -p "$dst_dir" 2>/dev/null; then failed=1; continue; fi
    for entry in "$src_dir"/* "$src_dir"/.[!.]* "$src_dir"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=${entry##*/}
      if [ -d "$entry" ] && [ ! -L "$entry" ]; then
        set -- "$@" "$rest/$name"
        continue
      fi
      landing="$dst_dir/$name"
      if [ -e "$landing" ] || [ -L "$landing" ]; then
        if [ -L "$entry" ] && [ -L "$landing" ] \
          && [ "$(readlink "$entry")" = "$(readlink "$landing")" ]; then continue; fi
        if [ -f "$entry" ] && [ ! -L "$entry" ] && [ -f "$landing" ] \
          && [ ! -L "$landing" ] && cmp -s "$entry" "$landing"; then continue; fi
        echo "=== conflicting profile file: $landing ===" >> "$log" 2>&1 || true
        failed=1
        continue
      fi
      if [ -L "$entry" ]; then
        if ! cp -Ppn "$entry" "$landing" 2>/dev/null; then
          failed=1
        fi
      else
        if ! cp -pn "$entry" "$landing" 2>/dev/null || ! cmp -s "$entry" "$landing"; then
          failed=1
        fi
        chmod u+w "$landing" 2>/dev/null || true
      fi
    done
  done
  [ -z "$failed" ]
}

# Steam Cloud stuff
migrate_user_paths() {
  profile=$1
  migration_failed=0
  for pair in \
    "Local Settings/Application Data|AppData/Local|../AppData/Local" \
    "Application Data|AppData/Roaming|./AppData/Roaming" \
    "My Documents|Documents|./Documents"; do
    old_rel=${pair%%|*}
    rest=${pair#*|}
    new_rel=${rest%%|*}
    link=${rest#*|}
    old="$profile/$old_rel"
    new="$profile/$new_rel"
    case "$(readlink "$new" 2>/dev/null || true)" in
      *"drive_c/users/steamuser/$old_rel") rm -f "$new" 2>/dev/null || true ;;
    esac
    if [ -L "$new" ]; then
      echo "=== $new_rel is a link, rebuild the prefix for cloud saves ===" \
        >> "$log" 2>&1 || true
      migration_failed=1
      continue
    fi
    held=
    for rel in "$old_rel" "$new_rel"; do
      probe=$rel
      while [ "$probe" != "${probe%/*}" ]; do
        probe=${probe%/*}
        if [ -L "$profile/$probe" ]; then held=$probe; break; fi
      done
      if [ -n "$held" ]; then break; fi
    done
    if [ -n "$held" ]; then
      echo "=== $held is a link, rebuild the prefix for cloud saves ===" \
        >> "$log" 2>&1 || true
      migration_failed=1
      continue
    fi
    if [ -e "$old" ] && [ ! -L "$old" ]; then
      if ! merge_user_dir "$old" "$new"; then
        echo "=== $old_rel did not merge into $new_rel, left in place ===" \
          >> "$log" 2>&1 || true
        migration_failed=1
        continue
      fi
      backup="$old BACKUP"
      backup_number=2
      while [ -e "$backup" ] || [ -L "$backup" ]; do
        backup="$old BACKUP $backup_number"
        backup_number=$((backup_number + 1))
      done
      if ! mv "$old" "$backup" 2>> "$log"; then
        echo "=== $old_rel could not be moved aside, cloud saves stay split ===" \
          >> "$log" 2>&1 || true
        migration_failed=1
        continue
      fi
    fi
    if [ ! -e "$old" ] && [ ! -L "$old" ]; then
      mkdir -p "${old%/*}" 2>/dev/null || true
      ln -s "$link" "$old" 2>/dev/null \
        || echo "=== $old_rel could not be aliased onto $new_rel ===" >> "$log" 2>&1 \
        || true
    elif [ -L "$old" ] && [ "$(readlink "$old")" != "$link" ]; then
      rm -f "$old" 2>/dev/null || true
      ln -s "$link" "$old" 2>/dev/null \
        || echo "=== $old_rel could not be aliased onto $new_rel ===" >> "$log" 2>&1 \
        || true
    fi
  done
  [ "$migration_failed" -eq 0 ]
}

lay_out_proton_profile() {
  users="${1:-$WINEPREFIX}/drive_c/users"
  if [ -d "$users/crossover" ] && [ ! -L "$users/crossover" ]; then
    echo "=== prefix predates the steamuser layout, rebuild it for cloud saves ===" \
      >> "$log" 2>&1 || true
    return 0
  fi
  profile="$users/steamuser"
  if [ -L "$profile" ]; then
    echo "=== the profile is a link, rebuild the prefix for cloud saves ===" \
      >> "$log" 2>&1 || true
    return 0
  fi
  mkdir -p "$profile" 2>/dev/null || return 0
  for folder in Documents Desktop Downloads Music Pictures Videos Templates \
      AppData/Local AppData/Roaming; do
    mkdir -p "$profile/$folder" 2>/dev/null || true
  done
  migrate_user_paths "$profile" || return 1
  if [ -L "$users/crossover" ] && [ ! -e "$users/crossover" ]; then
    rm -f "$users/crossover" 2>/dev/null || true
  fi
  if [ ! -e "$users/crossover" ] \
    && ln -s steamuser "$users/crossover" 2>/dev/null; then
    echo "=== pointed crossover at steamuser ===" >> "$log" 2>&1 || true
  fi
}

controller_ids() {
  printf '%s\n' "$1" | tr ',' '\n' | tr 'A-F' 'a-f' \
    | sed -n 's/^[[:space:]]*0x\([0-9a-f]\{4\}\)\/0x\([0-9a-f]\{4\}\)[[:space:]]*$/\1\/\2/p' \
    | sort -u
}

ids_without() {
  printf '%s\n' "$2" -- "$1" \
    | awk '$0 == "--" { s = 1; next } !s { b[$0]; next } $0 != "" && !($0 in b)'
}

hidraw_lines() {
  printf '%s\n' "$2" | while read -r id; do
    [ -n "$id" ] || continue
    if [ "$1" = add ]; then
      printf '%s\r\n' "[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\$id]" \
        '"Hidraw"=dword:00000000' ''
    else
      printf '%s\r\n' "[-HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\$id]" ''
    fi
  done
}

write_owned_controllers() {
  if printf '%s\n' "$1" | sed '/^$/d' | sort -u > "$controllers_file.new" \
    && mv -f "$controllers_file.new" "$controllers_file"; then
    return 0
  fi
  rm -f "$controllers_file.new"
  return 1
}

# Proton hides the controllers that Steam Input handles from the Wine process. CrossOver
# still reads a few directly (DualSense, DualShock 4, Switch 1 Pro Controller and Joy-Cons),
# so Hidraw=0 hides those too. The Switch controllers get Hidraw=0 even when Steam Input
# is off, to avoid silently breaking controller support in most games.
plan_hidden_controllers() {
  controllers_file="$STEAM_COMPAT_DATA_PATH/notproton-hidden-controllers"
  controllers_add=""
  controllers_remove=""
  controllers_wanted=""
  [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ ! -L "$controllers_file" ] || return 1
  owned=""
  [ ! -f "$controllers_file" ] || owned=$(sed -n '/^[0-9a-f]\{4\}\/[0-9a-f]\{4\}$/p' "$controllers_file")
  in_registry=""
  [ ! -f "$WINEPREFIX/system.reg" ] || in_registry=$(tr '[:upper:]' '[:lower:]' < "$WINEPREFIX/system.reg" \
    | sed -n 's/^\[system\\\\controlset001\\\\services\\\\winebus\\\\devices\\\\\([0-9a-f]\{4\}\/[0-9a-f]\{4\}\)\].*/\1/p' \
    | sort -u)
  if [ "$NOTPROTON_RAW_CONTROLLERS" != "1" ]; then
    controllers_wanted=$(ids_without "$(controller_ids "$SDL_GAMECONTROLLER_IGNORE_DEVICES")" \
      "$(controller_ids "$SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT")")
    controllers_wanted=$(printf '%s\n' "$controllers_wanted" 057e/2006 057e/2007 057e/2009 | sed '/^$/d' | sort -u)
    # Steam sends install scripts no ignore list. Keep the game's hidden controllers instead of clearing them.
    if [ "$verb" = run ]; then
      controllers_wanted=$(printf '%s\n' "$controllers_wanted" "$owned" | sed '/^$/d' | sort -u)
    fi
    controllers_wanted=$(ids_without "$controllers_wanted" "$(ids_without "$in_registry" "$owned")")
  fi
  controllers_add=$(ids_without "$controllers_wanted" "$in_registry")
  controllers_remove=$(ids_without "$owned" "$controllers_wanted")
  write_owned_controllers "$owned
$controllers_wanted"
}

# Sets Wine's DisableHidraw for games with "Disable hidraw" checked. When it's
# unchecked, the value is removed only if NotProton set it.
plan_disable_hidraw() {
  hidraw_file="$STEAM_COMPAT_DATA_PATH/notproton-disable-hidraw"
  hidraw_value=""
  [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ ! -L "$hidraw_file" ] || return 1
  hidraw_set=""
  [ ! -f "$WINEPREFIX/system.reg" ] || hidraw_set=$(tr '[:upper:]' '[:lower:]' < "$WINEPREFIX/system.reg" \
    | awk '/^\[/ { s = index($0, "[system\\\\controlset001\\\\services\\\\winebus]") == 1; next }
      s && $0 == "\"disablehidraw\"=dword:00000001" { print 1; exit }')
  if [ "$NOTPROTON_DISABLE_HIDRAW" = "1" ]; then
    [ -n "$hidraw_set" ] || hidraw_value='"DisableHidraw"=dword:00000001'
  elif [ -f "$hidraw_file" ] && [ -n "$hidraw_set" ]; then
    hidraw_value='"DisableHidraw"=-'
  fi
}

winebus_lines() {
  [ -n "$hidraw_value" ] || return 0
  printf '%s\r\n' '[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus]' "$hidraw_value" ''
}

# High Resolution doubles LogPixels and turning it off halves it
plan_logpixels() {
  dpi_value=""
  new_dpi=""
  read -r retina_was dpi <<EOF
$({ [ ! -f "$WINEPREFIX/user.reg" ] || tr '[:upper:]' '[:lower:]' < "$WINEPREFIX/user.reg"; } | awk '
  /^\[/ { s = 0
    if (index($0, "[software\\\\wine\\\\mac driver]") == 1) s = 1
    else if (index($0, "[control panel\\\\desktop]") == 1) s = 2
    next }
  s == 1 && $0 ~ /^"retinamode"="[yt1]/ { r = 1 }
  s == 2 && $0 ~ /^"logpixels"=dword:[0-9a-f]+$/ && length($0) <= 26 { d = substr($0, 19) }
  END { print r + 0, d }')
EOF
  [ -n "$dpi" ] || [ ! -f "$WINEPREFIX/system.reg" ] || dpi=$(tr '[:upper:]' '[:lower:]' < "$WINEPREFIX/system.reg" \
    | awk '/^\[/ { s = index($0, "[system\\\\controlset001\\\\hardware profiles\\\\current\\\\software\\\\fonts]") == 1; next }
      s && $0 ~ /^"logpixels"=dword:[0-9a-f]+$/ && length($0) <= 26 { print substr($0, 19); exit }')
  dpi=$((0x${dpi:-0}))
  [ "$dpi" -gt 0 ] || dpi=96
  if [ "$NOTPROTON_RETINA" = "1" ]; then
    [ "$retina_was" = 1 ] && [ "$dpi" -ge 110 ] || [ "$dpi" -gt 2147483647 ] || new_dpi=$((dpi * 2))
  elif [ "$retina_was" = 1 ]; then
    new_dpi=$((dpi / 2))
    [ "$new_dpi" -ge 96 ] || new_dpi=96
  fi
  [ -z "$new_dpi" ] || [ "$new_dpi" -eq "$dpi" ] || dpi_value=$(printf '"LogPixels"=dword:%08x' "$new_dpi")
}

video_lines() {
  [ "$verb" = waitforexitandrun ] || return 0
  printf '%s\r\n' '[HKEY_CURRENT_USER\Software\Wine\Mac Driver]' "$retina_line" ''
  [ -n "$dpi_value" ] || return 0
  printf '%s\r\n' '[HKEY_CURRENT_USER\Control Panel\Desktop]' "$dpi_value" ''
}

import_prefix_settings() {
  if [ "$NOTPROTON_RETINA" = "1" ]; then
    retina_line='"RetinaMode"="y"'
  else
    retina_line='"RetinaMode"=-'
  fi
  dpi_value=""
  controllers_planned=0
  if plan_hidden_controllers 2>/dev/null; then
    controllers_planned=1
  else
    controllers_add=""
    controllers_remove=""
    echo "=== could not track the hidden controllers, leaving them as they are ===" >> "$log" 2>&1 || true
  fi
  hidraw_planned=0
  if plan_disable_hidraw 2>/dev/null; then
    hidraw_planned=1
    if [ "$NOTPROTON_DISABLE_HIDRAW" = "1" ] && [ -n "$hidraw_value" ]; then
      : > "$hidraw_file" 2>/dev/null || hidraw_value=""
    fi
  else
    hidraw_value=""
    echo "=== could not track DisableHidraw, leaving it as it is ===" >> "$log" 2>&1 || true
  fi
  # Steam sends install scripts no launch options, so they keep the game's video settings.
  if [ "$verb" = waitforexitandrun ]; then
    plan_logpixels 2>/dev/null || dpi_value=""
  fi
  settings_file=$(mktemp "$WINEPREFIX/drive_c/notproton-settings.XXXXXX" 2>/dev/null) \
    || settings_file=""
  if [ -z "$settings_file" ] || ! { printf '%s\r\n' \
      'Windows Registry Editor Version 5.00' '' \
      '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
      '[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
      '[HKEY_CURRENT_USER\Software\Wine\WineDbg]' '"ShowCrashDialog"=dword:00000000' '' \
      && video_lines && printf '%s\r\n' \
      '[HKEY_LOCAL_MACHINE\Software\Classes\steam]' '"URL Protocol"=""' '' \
      '[HKEY_LOCAL_MACHINE\Software\Classes\steam\shell\open\command]' \
      '@="\"C:\\Program Files (x86)\\Steam\\steam.exe\" \"%1\""' '' \
      && hidraw_lines add "$controllers_add" && hidraw_lines remove "$controllers_remove" \
      && winebus_lines; } \
      > "$settings_file" 2>/dev/null; then
    [ -z "$settings_file" ] || rm -f "$settings_file"
    echo "=== could not write the prefix settings, launching without them ===" >> "$log" 2>&1 || true
    # the bridge staging still needs a built prefix
    without_lock_fds "$WINELOADER" wineboot --init >> "$log" 2>&1 || true
    return 0
  fi
  without_lock_fds "$WINELOADER" reg import "C:\\${settings_file##*/}" >> "$log" 2>&1 \
    && import_status=0 || import_status=$?
  rm -f "$settings_file"
  if [ "$import_status" -eq 0 ] && [ "$hidraw_planned" -eq 1 ] && [ "$NOTPROTON_DISABLE_HIDRAW" != "1" ]; then
    rm -f "$hidraw_file"
  fi
  if [ "$import_status" -eq 0 ] && [ -n "$controllers_add$controllers_remove$hidraw_value$dpi_value" ]; then
    # Wine only reads these keys when it starts, so restart Wine to apply them.
    without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
    without_lock_fds "$WINESERVER" -w >> "$log" 2>&1 || true
  fi
  if [ "$import_status" -eq 0 ] && [ "$hidraw_planned" -eq 1 ] && [ "$NOTPROTON_DISABLE_HIDRAW" = "1" ]; then
    echo "controllers: hidraw disabled (NOTPROTON_DISABLE_HIDRAW=1)" >> "$log" 2>&1 || true
  fi
  if [ "$import_status" -eq 0 ] && [ -n "$dpi_value" ]; then
    echo "video: LogPixels=$new_dpi" >> "$log" 2>&1 || true
  fi
  if [ "$import_status" -eq 0 ] && [ "$controllers_planned" -eq 1 ]; then
    write_owned_controllers "$controllers_wanted" 2>/dev/null || true
    if [ "$NOTPROTON_RAW_CONTROLLERS" = "1" ]; then
      echo "controllers: games read them directly (NOTPROTON_RAW_CONTROLLERS=1)" >> "$log" 2>&1 || true
    elif [ -n "$controllers_wanted" ]; then
      echo "controllers: $(printf '%s\n' "$controllers_wanted" | grep -c .) kept off hidraw" \
        >> "$log" 2>&1 || true
    fi
  fi
  [ "$import_status" -eq 0 ] \
    || echo "=== prefix settings import exited status=$import_status ===" >> "$log" 2>&1 || true
}

stage_step="runner check"
if [ -z "$np_build" ] || [ ! -d "$CX_ROOT/lib/wine" ]; then
  echo "=== build ${np_build:-(none recorded)} behind this compatibility tool is not set up, set it up in NotProton ===" >> "$log" 2>&1 || true
  show_alert "CrossOver is not set up" "The CrossOver build behind $(alert_safe "$np_display") is not set up. Set it up in NotProton, or pick another compatibility tool for this game."
  exit 1
fi
echo "runner: build $np_build ($np_display) at $CX_ROOT" >> "$log" 2>&1 || true

# Each CrossOver build needs its own template.
# FEX builds need two, one for FEX/arm64 Wine and one for Rosetta/AMD64 Wine
runner_id=""
[ -z "$np_build" ] || runner_id="crossover-$np_build-${wine_unix##*/}"

in_template_env() {
  prefix="$1"
  shift
  without_lock_fds \
    env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" TMPDIR="${TMPDIR:-/tmp}" \
    LANG="${LANG:-}" LC_ALL="${LC_ALL:-}" \
    PATH="$CX_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin" CX_ROOT="$CX_ROOT" CX_HOME="$CX_HOME" \
    WINEDLLPATH="$CX_ROOT/lib/wine/x86_64-windows:$wine_unix" \
    WINELOADER="$WINELOADER" WINESERVER="$WINESERVER" WINEPREFIX="$prefix" "$@"
}

seed_scratch=""
seed_building=0
# shellcheck disable=SC2329 # the traps in seed_prefix_from_template invoke this
abandon_seed() {
  if [ -n "$seed_scratch" ]; then
    if [ "$seed_building" -eq 1 ]; then
      in_template_env "$seed_scratch" "$WINESERVER" -k >/dev/null 2>&1 || true
      in_template_env "$seed_scratch" "$WINESERVER" -w >/dev/null 2>&1 || exit "$1"
    fi
    rm -rf "$seed_scratch" 2>/dev/null || true
  fi
  exit "$1"
}

prefix_server_dir() {
  [ -n "${1:-$WINEPREFIX}" ] || return 1
  ids=$(stat -f '%d-%i' "${1:-$WINEPREFIX}" 2>/dev/null) || return 1
  [ -n "$ids" ] || return 1
  printf '/tmp/.wine-%s/server-%s' "$(id -u)" \
    "$(printf '%s' "$ids" | awk -F- '{printf "%x-%x", $1, $2}')"
}

sweep_dead_seeds() {
  for leftover in "$@"; do
    [ -d "$leftover" ] && [ ! -L "$leftover" ] || continue
    case "${leftover##*.}" in ''|0|*[!0-9]*) continue ;; esac
    [ "$(stat -f %u "$leftover" 2>/dev/null)" = "$(id -u)" ] || continue
    kill -0 "${leftover##*.}" 2>/dev/null && continue
    stale_server=$(prefix_server_dir "$leftover") || continue
    if [ -d "$stale_server" ]; then
      stale_users=$(lsof -t +D "$stale_server" 2>&1 || true)
      [ -z "$stale_users" ] || continue
    fi
    rm -rf "$leftover" 2>/dev/null || true
  done
}

same_volume() {
  one=$(stat -f %d "$1" 2>/dev/null) || return 1
  two=$(stat -f %d "$2" 2>/dev/null) || return 1
  [ "$one" = "$two" ]
}

# On non-APFS file systems, a full copy is made rather than a clone.
volume_clones() {
  device=$(stat -f %Sd "$1" 2>/dev/null) || return 1
  mount | grep -q "^/dev/$device on .* (apfs[,)]"
}

# Built in a temporary folder and renamed when the build finishes, so a broken template is never used
build_prefix_template() {
  sweep_dead_seeds "$template_dir"/pfx.building.*
  seed_scratch="$template_dir/pfx.building.$$"
  mkdir "$seed_scratch" || return 1
  echo "=== building the prefix template for $runner_id ===" >> "$log" 2>&1 || true
  # The Steam user folders have to exist before wineboot runs, or wineboot will make its own
  # and cloud saves end up in the wrong place.
  lay_out_proton_profile "$seed_scratch" || return 1
  seed_building=1
  in_template_env "$seed_scratch" "$WINELOADER" wineboot --init >> "$log" 2>&1 &
  initialized=0
  wait $! || initialized=$?
  in_template_env "$seed_scratch" "$WINESERVER" -w >> "$log" 2>&1 &
  if ! wait $!; then
    echo "=== template server did not finish, leaving its staging folder intact ===" >> "$log" 2>&1 || true
    seed_scratch=""
    seed_building=0
    return 1
  fi
  seed_building=0
  if [ "$initialized" -ne 0 ] || [ ! -s "$seed_scratch/system.reg" ] \
    || [ ! -s "$seed_scratch/user.reg" ] || [ ! -s "$seed_scratch/userdef.reg" ]; then
    echo "=== wineboot produced no template, this game gets its own prefix ===" \
      >> "$log" 2>&1 || true
    rm -rf "$seed_scratch" 2>/dev/null || true
    seed_scratch=""
    return 1
  fi
  if [ ! -e "$template_dir/pfx" ] && [ ! -L "$template_dir/pfx" ]; then
    mv "$seed_scratch" "$template_dir/pfx" 2>/dev/null || true
  fi
  rm -rf "$seed_scratch" 2>/dev/null || true
  seed_scratch=""
  [ -f "$template_dir/pfx/system.reg" ]
}

install_seed_tree() (
  set -- ""
  while [ "$#" -gt 0 ]; do
    relative=$1
    shift
    source_dir="$seed_scratch$relative"
    target_dir="$WINEPREFIX$relative"
    [ -d "$target_dir" ] && [ ! -L "$target_dir" ] || return 1
    [ -r "$source_dir" ] && [ -x "$source_dir" ] || return 1
    for source in "$source_dir"/* "$source_dir"/.[!.]* "$source_dir"/..?*; do
      [ -e "$source" ] || [ -L "$source" ] || continue
      name=${source##*/}
      if [ -z "$relative" ]; then
        case "$name" in system.reg|.update-timestamp) continue ;; esac
      fi
      target="$target_dir/$name"
      if [ -d "$source" ] && [ ! -L "$source" ]; then
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
          mkdir "$target" || return 1
        fi
        [ -d "$target" ] && [ ! -L "$target" ] || return 1
        set -- "$@" "$relative/$name"
      elif [ -e "$target" ] || [ -L "$target" ]; then
        case "$relative/$name" in
          /drive_c/users/steamuser/*) continue ;;
        esac
        [ -L "$source" ] && [ -L "$target" ] \
          && [ "$(readlink "$source")" = "$(readlink "$target")" ] || return 1
      elif [ -L "$source" ]; then
        ln -sh "$(readlink "$source")" "$target" || return 1
        [ -L "$target" ] && [ "$(readlink "$source")" = "$(readlink "$target")" ] || return 1
      elif [ -f "$source" ]; then
        ln -h "$source" "$target" || return 1
        [ ! -L "$target" ] && [ "$source" -ef "$target" ] || return 1
      else
        return 1
      fi
    done
  done
  ln -h "$seed_scratch/system.reg" "$WINEPREFIX/system.reg" \
    && [ ! -L "$WINEPREFIX/system.reg" ] \
    && [ "$seed_scratch/system.reg" -ef "$WINEPREFIX/system.reg" ] || return 1
  if [ -f "$seed_scratch/.update-timestamp" ]; then
    ln -h "$seed_scratch/.update-timestamp" "$WINEPREFIX/.update-timestamp" || return 1
  fi
)

copy_template_into_prefix() {
  seed_scratch="$STEAM_COMPAT_DATA_PATH/pfx.seeding.$$"
  if ! mkdir "$seed_scratch" 2>/dev/null; then
    echo "=== prefix staging folder is occupied, skipping the template ===" >> "$log" 2>&1 || true
    seed_scratch=""
    return 0
  fi
  if same_volume "$template_dir" "$STEAM_COMPAT_DATA_PATH" && volume_clones "$template_dir"; then
    how="cloned this prefix from the $runner_id template"
    cp -c -R "$template_dir/pfx/." "$seed_scratch" 2>/dev/null && copied=0 || copied=$?
  else
    how="copied this prefix from the $runner_id template, not a clone"
    cp -R "$template_dir/pfx/." "$seed_scratch" 2>/dev/null && copied=0 || copied=$?
  fi
  if [ "$copied" -eq 0 ] && prefix_is_bare && install_seed_tree; then
    echo "=== $how ===" >> "$log" 2>&1 || true
  else
    echo "=== could not seed from the template, wine builds this prefix itself ===" \
      >> "$log" 2>&1 || true
  fi
  rm -rf "$seed_scratch" 2>/dev/null || true
  seed_scratch=""
}

prefix_is_bare() (
  set -- ""
  while [ "$#" -gt 0 ]; do
    relative=$1
    shift
    directory="$WINEPREFIX$relative"
    [ -d "$directory" ] && [ ! -L "$directory" ] \
      && [ -r "$directory" ] && [ -x "$directory" ] || return 1
    for node in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
      [ -e "$node" ] || [ -L "$node" ] || continue
      part="$relative/${node##*/}"
      if [ -L "$node" ]; then
        if [ "$part" = /dosdevices/s: ] && [ "$(readlink "$node")" = "$(game_drive_record)" ]; then
          continue
        fi
        case "$part:$(readlink "$node")" in
          /dosdevices/c::../drive_c|/dosdevices/z::/|/drive_c/users/crossover:steamuser|\
          '/drive_c/users/steamuser/My Documents:./Documents'|\
          '/drive_c/users/steamuser/Application Data:./AppData/Roaming'|\
          '/drive_c/users/steamuser/Local Settings/Application Data:../AppData/Local') continue ;;
          *) return 1 ;;
        esac
      fi
      case "$part" in
        /drive_c|/drive_c/users|/drive_c/users/steamuser|/dosdevices)
          [ -d "$node" ] || return 1 ;;
        /drive_c/users/steamuser/*)
          [ -d "$node" ] || [ -f "$node" ] || return 1 ;;
        *) return 1 ;;
      esac
      if [ -d "$node" ]; then set -- "$@" "$part"; fi
    done
  done
)

template_identity() (
  stat -f '%d:%i:%c' "$CX_ROOT" || return 1
  /usr/bin/shasum -a 256 < "$np_tool_dir/run" || return 1
  cd "$CX_ROOT" || return 1
  set -- "$WINELOADER" "$WINESERVER" share/wine/wine.inf
  for file in lib/wine/*-windows/ntdll.dll lib/wine/*-windows/lsteamclient.dll \
    lib/wine/*-unix/lsteamclient.so; do
    [ ! -f "$file" ] || set -- "$@" "$file"
  done
  /usr/bin/shasum -a 256 "$@"
)

# Each game's prefix is copied from one template (per runner) instead of running wineboot.
# On APFS the copy is a clone, so it takes almost no space.
seed_prefix_from_template() {
  sweep_dead_seeds "$STEAM_COMPAT_DATA_PATH"/pfx.seeding.*
  [ -n "$runner_id" ] || return 0
  if ! prefix_is_bare; then
    [ -f "$WINEPREFIX/system.reg" ] \
      || echo "=== prefix is not empty or a standalone Steam profile, skipping the template ===" \
        >> "$log" 2>&1 || true
    return 0
  fi
  # Since a user can have more than one Steam library and libraries can be on different drives,
  # the template is stored alongside the Steam library to support APFS cloning.
  template_cache="$(dirname "$STEAM_COMPAT_DATA_PATH")/notproton-template"
  template_lock="$(dirname "$STEAM_COMPAT_DATA_PATH")/.notproton-template.lock"
  [ ! -L "$template_cache" ] && [ ! -L "$template_lock" ] || return 0
  [ ! -e "$template_lock" ] || [ -f "$template_lock" ] || return 0
  if ! { : >> "$template_lock"; } 2>/dev/null; then
    echo "=== prefix template cache is not writable, skipping the template ===" >> "$log" 2>&1 || true
    return 0
  fi
  exec 9>> "$template_lock"
  if ! /usr/bin/lockf -s -t 0 9; then
    exec 9>&-
    echo "=== prefix templates are busy, wine builds this prefix itself ===" >> "$log" 2>&1 || true
    return 0
  fi
  template_dir="$template_cache/$runner_id"
  if [ -L "$template_cache" ] || [ -L "$template_dir" ] \
    || ! mkdir -p "$template_dir"; then exec 9>&-; return 0; fi
  if ! identity=$(template_identity); then exec 9>&-; return 0; fi
  trap 'abandon_seed 143' TERM
  trap 'abandon_seed 130' INT
  trap 'abandon_seed 129' HUP
  if [ -L "$template_dir/pfx" ] || [ -L "$template_dir/ready" ] \
    || { [ -e "$template_dir/pfx" ] && [ ! -d "$template_dir/pfx" ]; } \
    || { [ -e "$template_dir/ready" ] && [ ! -f "$template_dir/ready" ]; }; then
    exec 9>&-
    trap - TERM INT HUP
    return 0
  fi
  if [ ! -s "$template_dir/pfx/system.reg" ] \
    || [ "$(cat "$template_dir/ready" 2>/dev/null)" != "$identity" ]; then
    if ! rm -f "$template_dir/ready" || ! rm -rf "$template_dir/pfx"; then
      echo "=== could not invalidate the old prefix template, skipping it ===" >> "$log" 2>&1 || true
      exec 9>&-
      trap - TERM INT HUP
      return 0
    fi
    if build_prefix_template; then
      if ! printf '%s\n' "$identity" > "$template_dir/ready"; then
        rm -f "$template_dir/ready" 2>/dev/null || true
      fi
    fi
  fi
  if [ "$(cat "$template_dir/ready" 2>/dev/null)" = "$identity" ] \
    && [ -s "$template_dir/pfx/system.reg" ]; then
    copy_template_into_prefix
  fi
  exec 9>&-
  trap - TERM INT HUP
}

prepare_prefix_directory() {
  mkdir -p "$STEAM_COMPAT_DATA_PATH" || return 1
  prefix_lock="$STEAM_COMPAT_DATA_PATH/.notproton-prefix.lock"
  [ ! -L "$prefix_lock" ] && { [ ! -e "$prefix_lock" ] || [ -f "$prefix_lock" ]; } || return 1
  exec 8>> "$prefix_lock"
  if ! /usr/bin/lockf -s -t 0 8; then
    echo "=== another launch is preparing this prefix ===" >> "$log" 2>&1 || true
    /usr/sbin/lsof -- "$prefix_lock" >> "$log" 2>&1 || true
    return 1
  fi
  for interrupted in "$STEAM_COMPAT_DATA_PATH"/pfx.replaced.*; do
    [ -e "$interrupted" ] || [ -L "$interrupted" ] || continue
    echo "=== interrupted prefix replacement needs recovery: $interrupted ===" >> "$log" 2>&1 || true
    show_alert "Prefix recovery required" "An interrupted prefix replacement may hold saved games. Do not delete this prefix. Check its notproton-run.log for the recovery folder."
    exit 1
  done
  mkdir -p "$WINEPREFIX"
}

game_drive_record() {
  record="$STEAM_COMPAT_DATA_PATH/notproton-game-drive"
  [ -f "$record" ] && [ ! -L "$record" ] && cat "$record" 2>/dev/null
}

record_game_drive() {
  record="$STEAM_COMPAT_DATA_PATH/notproton-game-drive"
  [ "$(game_drive_record)" != "$1" ] && [ ! -L "$record" ] || return 0
  { printf '%s\n' "$1" > "$record.new" && mv -f "$record.new" "$record"; } 2>/dev/null \
    || rm -f "$record.new" 2>/dev/null || true
}

restart_for_drive() {
  # Wine only picks up a new drive when it starts.
  without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
  without_lock_fds "$WINESERVER" -w >> "$log" 2>&1 || true
}

unmap_game_drive() {
  [ -L "$drive" ] && [ "$(readlink "$drive")" = "$(game_drive_record)" ] || return 0
  rm -f "$drive" || return 0
  rm -f "$STEAM_COMPAT_DATA_PATH/notproton-game-drive" 2>/dev/null || true
  echo "=== removed drive S:, the game is not in a Steam library ===" >> "$log" 2>&1 || true
  restart_for_drive
}

# Like Proton, the game's Steam library gets drive S: so the game does not run from Z:.
map_game_drive() {
  drive="$WINEPREFIX/dosdevices/s:"
  [ -d "$WINEPREFIX/dosdevices" ] && [ ! -L "$WINEPREFIX/dosdevices" ] || return 0
  library=""
  set -f
  old_ifs=$IFS
  IFS=:
  for path in $STEAM_COMPAT_LIBRARY_PATHS; do
    path=${path%/}
    [ -n "$path" ] || continue
    case "$STEAM_COMPAT_INSTALL_PATH/" in
      "$path"/*) if [ "${#path}" -gt "${#library}" ]; then library=$path; fi ;;
    esac
  done
  IFS=$old_ifs
  set +f
  if [ -z "$library" ]; then
    unmap_game_drive
    return 0
  fi
  target=$library
  if real=$(cd -P -- "$library" 2>/dev/null && pwd) && [ "${real##*/}" = steamapps ]; then
    parent=${real%/*}
    if [ -n "$parent" ] && [ -w "$parent" ] \
      && [ "$(stat -f %d "$real")" = "$(stat -f %d "$parent")" ]; then
      target=$parent
    fi
  fi
  if [ -L "$drive" ]; then
    current=$(readlink "$drive") || return 0
    if [ "$current" = "$target" ]; then
      record_game_drive "$target"
      return 0
    fi
    if [ "$current" != "$(game_drive_record)" ]; then
      echo "=== drive S: already points to $current, left in place ===" >> "$log" 2>&1 || true
      return 0
    fi
    rm -f "$drive" || return 0
  elif [ -e "$drive" ]; then
    echo "=== drive S: is not a link, left in place ===" >> "$log" 2>&1 || true
    return 0
  fi
  if ln -s "$target" "$drive" 2>> "$log"; then
    record_game_drive "$target"
    echo "=== mapped drive S: to $target ===" >> "$log" 2>&1 || true
    restart_for_drive
  else
    echo "=== could not map drive S: to $target ===" >> "$log" 2>&1 || true
  fi
}

# Implementation of Proton's create_fonts_symlinks().
link_fonts() {
  [ -f "$WINEPREFIX/system.reg" ] || return 0
  fonts_dir="$WINEPREFIX/drive_c/windows/Fonts"
  mkdir -p "$fonts_dir" 2>> "$log" || return 0
  for dir in "$np_support/fonts" "$CX_ROOT/share/wine/fonts"; do
    for src in "$dir"/*.ttf "$dir"/*.ttc; do
      [ -f "$src" ] || continue
      name=$(basename "$src")
      case "$app_id:$name" in
        1313860:arial.ttf|1506830:arial.ttf) src="$dir/alt/$name" ;;
      esac
      dst="$fonts_dir/$name"
      if [ -L "$dst" ]; then
        rm -f "$dst" && ln -s "$src" "$dst" 2>> "$log" || true
      elif [ ! -e "$dst" ]; then
        ln -s "$src" "$dst" 2>> "$log" || true
      fi
    done
  done
}

# Wine loads its own VC++ runtime over Microsoft's, which breaks some games
native_vc_runtime() {
  for name in concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait msvcp140_codecvt_ids \
    vcamp140 vccorlib140 vcomp140 vcruntime140 vcruntime140_1; do
    dll="$WINEPREFIX/drive_c/windows/system32/$name.dll"
    [ -f "$dll" ] || continue
    if [ "$(dd if="$dll" bs=1 skip=64 count=16 2>/dev/null)" != "Wine builtin DLL" ]; then
      printf '%s=n,b;' "$name"
    fi
  done
}

if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
  export WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  stage_step="prefix lock"
  prepare_prefix_directory
  msync_from=environment
  if np_from_defaults WINEMSYNC; then msync_from=${np_defaults_file##*/}; fi
  if [ -z "$WINEMSYNC" ] && [ "$verb" != waitforexitandrun ] \
    && [ -r "$STEAM_COMPAT_DATA_PATH/notproton-msync" ]; then
    WINEMSYNC=$(tr -d ' \t\n' \
      < "$STEAM_COMPAT_DATA_PATH/notproton-msync" 2>/dev/null || true)
    msync_from=carried-over
  fi
  [ -n "$WINEMSYNC" ] || msync_from=default
  export WINEMSYNC="${WINEMSYNC:-0}"
  printf '%s' "$WINEMSYNC" \
    > "$STEAM_COMPAT_DATA_PATH/notproton-msync" 2>/dev/null || true
  stage_step="prefix build check"
  note_other_build
  stage_step="prefix arch check"
  refuse_foreign_prefix
  claim_prefix
  stage_step="prefix switch check"
  offer_switch_rebuild
  echo "sync: WINEMSYNC=$WINEMSYNC from $msync_from" >> "$log" 2>&1 || true
  if [ "${wine_unix##*/}" = aarch64-unix ]; then
    echo "fex: FEX_X87REDUCEDPRECISION=$FEX_X87REDUCEDPRECISION from $fex_from" >> "$log" 2>&1 || true
  else
    echo "avx: ROSETTA_ADVERTISE_AVX=$ROSETTA_ADVERTISE_AVX from $avx_from" >> "$log" 2>&1 || true
  fi
  without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
  stage_step="prefix seed"
  seed_prefix_from_template
  stage_step="profile layout"
  if ! lay_out_proton_profile; then
    show_alert "Saved-game folders need attention" "NotProton left the conflicting files in place. Open this prefix's notproton-run.log for details before trying again."
    exit 1
  fi
  [ "$verb" != waitforexitandrun ] || echo "video: RetinaMode=${NOTPROTON_RETINA:-0}" >> "$log" 2>&1 || true
  stage_step="game drive"
  map_game_drive
  stage_step="prefix settings"
  import_prefix_settings
  stage_step="fonts"
  link_fonts
  # A prefix that Wine built just now only has dosdevices from this point on.
  stage_step="game drive"
  map_game_drive
fi

bridge_src="$np_support/bridge"
prefix_steam="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
verify_runner() {
  if [ ! -d "$bridge_src/wine/$np_build" ]; then
    echo "=== no patched ntdll for build $np_build in the bridge, set it up in NotProton ===" >> "$log" 2>&1 || true
    return
  fi
  for arch in x86_64-windows i386-windows aarch64-windows; do
    staged="$bridge_src/wine/$np_build/$arch/ntdll.dll"
    live="$CX_ROOT/lib/wine/$arch/ntdll.dll"
    [ -f "$staged" ] || continue
    if [ ! -f "$live" ]; then
      echo "=== runner has no $arch ntdll, set up the runner in NotProton ===" >> "$log" 2>&1 || true
    elif ! cmp -s "$staged" "$live"; then
      echo "=== runner $arch ntdll is not the patched copy, set up the runner in NotProton ===" >> "$log" 2>&1 || true
    fi
  done
  for arch in i386-windows x86_64-windows "${wine_unix##*/}"; do
    case "$arch" in
      *-unix) name="lsteamclient.so" ;;
      *) name="lsteamclient.dll" ;;
    esac
    [ -f "$CX_ROOT/lib/wine/$arch/$name" ] && continue
    echo "=== runner is missing $arch/$name, set up the runner in NotProton ===" >> "$log" 2>&1 || true
  done
}
install_lsteamclient_trigger() {
  src="$bridge_src/i386-windows/lsteamclient.dll"
  dst="$WINEPREFIX/drive_c/windows/syswow64/lsteamclient.dll"
  [ -f "$src" ] && [ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || return 0
  cmp -s "$src" "$dst" && return 0
  if place_bridge_file i386-windows/lsteamclient.dll "$dst"; then
    echo "=== installed syswow64 lsteamclient trigger ===" >> "$log" 2>&1 || true
  else
    echo "=== could not copy i386-windows/lsteamclient.dll to $dst ===" >> "$log" 2>&1 || true
    return 1
  fi
}

# A fix to match Proton
install_legacy_steam_dll() {
  src="$bridge_src/legacycompat/Steam.dll"
  dst="$WINEPREFIX/drive_c/windows/syswow64/Steam.dll"
  [ -f "$src" ] && [ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || return 0
  cmp -s "$src" "$dst" && return 0
  if place_bridge_file legacycompat/Steam.dll "$dst"; then
    echo "=== installed legacy Steam.dll ===" >> "$log" 2>&1 || true
  else
    echo "=== could not copy legacycompat/Steam.dll to $dst ===" >> "$log" 2>&1 || true
  fi
}

# Steam runs a Windows game's installscript.vdf by invoking the standalone
# evaluator through the compat tool, the same way the linux client does, but
# the binaries are missing on macOS, so...
install_legacycompat() {
  src="$bridge_src/legacycompat"
  dst="$STEAM_COMPAT_CLIENT_INSTALL_PATH/legacycompat"
  [ -d "$src" ] && [ -n "$STEAM_COMPAT_CLIENT_INSTALL_PATH" ] || return 0
  mkdir -p "$dst" || return 0
  for f in "$src"/*; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    cmp -s "$f" "$dst/$b" && continue
    if cp -c -f "$f" "$dst/$b" 2>> "$log"; then
      echo "=== installed legacycompat/$b ===" >> "$log" 2>&1 || true
    else
      echo "=== could not copy legacycompat/$b to $dst/$b ===" >> "$log" 2>&1 || true
    fi
  done
}

# Steam on Linux symlinks this for every compat tool launch. Is needed for some legacy games.
link_legacy_steam_dll() {
  src="$STEAM_COMPAT_CLIENT_INSTALL_PATH/legacycompat/Steam.dll"
  [ -n "$STEAM_COMPAT_INSTALL_PATH" ] && [ -f "$src" ] || return 0
  dst="$(dirname "$STEAM_COMPAT_INSTALL_PATH")/Steam.dll"
  [ -L "$dst" ] || [ ! -e "$dst" ] || return 0
  [ "$(readlink "$dst" 2>/dev/null)" = "$src" ] && return 0
  if ln -sfn "$src" "$dst" 2>> "$log"; then
    chflags -h hidden "$dst" 2>/dev/null || true
    echo "=== linked legacy Steam.dll at $dst ===" >> "$log" 2>&1 || true
  else
    echo "=== could not link legacy Steam.dll at $dst ===" >> "$log" 2>&1 || true
  fi
}

bridge_files="steamclient64.dll steamclient.dll tier0_s64.dll vstdlib_s64.dll"
bridge_files="$bridge_files lsteamclient.dll lsteamclient.so steam.exe"
# A clone cannot cross drives, so a prefix on another drive clones from a copy of the
# bridge kept beside that drive's templates.
bridge_origin() {
  origin="$bridge_src/$1"
  [ -n "$bridge_cache" ] || return 0
  cached="$bridge_cache/$1"
  for d in "${bridge_cache%/*}" "$bridge_cache" "${cached%/*}"; do
    [ ! -L "$d" ] || return 0
  done
  mkdir -p "${cached%/*}" 2>/dev/null || return 0
  if ! cmp -s "$origin" "$cached"; then
    if ! { cp -p "$origin" "$cached.$$" && mv -f "$cached.$$" "$cached"; } 2>/dev/null; then
      rm -f "$cached.$$"
      return 0
    fi
  fi
  origin="$cached"
}
place_bridge_file() {
  bridge_origin "$1"
  cp -c -fp "$origin" "$2" 2>/dev/null || cp -fp "$bridge_src/$1" "$2" 2>> "$log"
}
if [ -d "$bridge_src" ] && [ -n "$WINEPREFIX" ]; then
  stage_step="bridge staging"
  mkdir -p "$prefix_steam"
  bridge_cache=""
  if [ -n "$STEAM_COMPAT_DATA_PATH" ] && ! same_volume "$bridge_src" "$STEAM_COMPAT_DATA_PATH" \
    && volume_clones "$STEAM_COMPAT_DATA_PATH"; then
    bridge_cache="$(dirname "$STEAM_COMPAT_DATA_PATH")/notproton-template/bridge"
  fi
  bridge_matches=1
  for f in $bridge_files; do
    src="$bridge_src/$f"
    if [ "$f" = lsteamclient.so ]; then
      src="$bridge_src/${wine_unix##*/}/$f"
    fi
    if ! cmp -s "$src" "$prefix_steam/$f"; then
      bridge_matches=0
      break
    fi
  done
  if [ "$bridge_matches" -eq 1 ]; then
    echo "=== bridge already staged ===" >> "$log" 2>&1 || true
  else
    unstaged=0
    for f in $bridge_files; do
      rel="$f"
      if [ "$f" = lsteamclient.so ]; then
        rel="${wine_unix##*/}/$f"
      fi
      src="$bridge_src/$rel"
      if [ ! -f "$src" ]; then
        echo "=== bridge missing $f ===" >> "$log" 2>&1 || true
        continue
      fi
      cmp -s "$src" "$prefix_steam/$f" && continue
      if ! place_bridge_file "$rel" "$prefix_steam/$f"; then
        echo "=== could not copy $rel to $prefix_steam/$f ===" >> "$log" 2>&1 || true
        unstaged=1
      fi
    done
    if [ "$unstaged" -eq 1 ]; then
      show_alert "Steam files could not be copied" "NotProton could not copy a file into this game's prefix. Open this prefix's notproton-run.log for details."
      exit 1
    fi
  fi
  for f in "$prefix_steam"/*.dll "$prefix_steam"/*.so "$prefix_steam"/*.exe; do
    [ -f "$f" ] || continue
    case " $bridge_files " in
      *" $(basename "$f") "*) ;;
      *) rm -f "$f" && echo "=== pruned stale $(basename "$f") ===" >> "$log" 2>&1 ;;
    esac
  done
  verify_runner
  if ! install_lsteamclient_trigger; then
    show_alert "Steam files could not be copied" "NotProton could not copy a file into this game's prefix. Open this prefix's notproton-run.log for details."
    exit 1
  fi
  install_legacy_steam_dll
  export WINEDLLPATH="$prefix_steam:$WINEDLLPATH"
  # If the same DLL appears twice in WINEDLLOVERRIDES, the last entry wins.
  vc_overrides=$(native_vc_runtime)
  export WINEDLLOVERRIDES="${vc_overrides}${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}steamclient=n;steamclient64=n;lsteamclient=b"
  native_client="$STEAM_COMPAT_CLIENT_INSTALL_PATH"
  if [ -z "$native_client" ]; then
    native_client="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$native_client"
  fi
  install_legacycompat
  link_legacy_steam_dll
  echo "=== bridge staged into $prefix_steam ===" >> "$log" 2>&1 || true
  echo "WINEDLLPATH=$WINEDLLPATH" >> "$log" 2>&1 || true
  echo "WINEDLLOVERRIDES=$WINEDLLOVERRIDES" >> "$log" 2>&1 || true
  echo "STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAM_COMPAT_CLIENT_INSTALL_PATH" >> "$log" 2>&1 || true
fi

export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all}"
exec 8>&-
trap - EXIT
printf 'launch_args=%s\n' "$launch_args" >> "$log" 2>&1 || true
printf '=== launching (%s): %s %s ===\n' "$verb" "$WINELOADER" "$*" >> "$log" 2>&1 || true

target="$1"
# A game can arrive as a URL with no install path to match, so the verb has to decide the route.
case "$verb" in
  waitforexitandrun) foreground=1 ;;
  *) foreground=0 ;;
esac

shim_exe="C:\\Program Files (x86)\\Steam\\steam.exe"

if [ "$foreground" = 0 ]; then
  status=0  # set -e would exit before the status is read
  case "$verb" in
    # runinprefix is the one verb the Linux client keeps on the raw loader.
    runinprefix)
      echo "=== running helper on raw loader: $* ===" >> "$log" 2>&1 || true
      "$WINELOADER" "$@" >> "$log" 2>&1 || status=$?
      ;;
    *)
      # A helper target can be a URL, which steam.exe resolves.
      echo "=== running helper through the shim: $* ===" >> "$log" 2>&1 || true
      "$WINELOADER" "$shim_exe" "$@" >> "$log" 2>&1 || status=$?
      ;;
  esac
  echo "=== helper exited status=$status ===" >> "$log" 2>&1 || true
  exit $status
fi

# Fixes CrossOver window focus issues
steam_root="$(dirname "$(dirname "$(dirname "$STEAM_COMPAT_DATA_PATH")")")"
manifest="$steam_root/steamapps/appmanifest_$app_id.acf"
find_client_root "$STEAM_COMPAT_CLIENT_INSTALL_PATH"
# Icon stuff
read_app_meta
game_name="$meta_name"
if [ -z "$game_name" ] && [ -f "$manifest" ]; then
  game_name=$(sed -n 's/.*"name"[[:space:]]*"\(.*\)".*/\1/p' "$manifest" | head -1)
fi
[ -z "$game_name" ] && game_name=$(basename "$STEAM_COMPAT_INSTALL_PATH")
[ -z "$game_name" ] && game_name="Steam Game"
# shellcheck disable=SC1003 # the pair deletes a literal backslash, not a quote
bundle_name=$(printf '%s' "$game_name" | tr -d '/:"`$\\')
bundle_name=${bundle_name#"${bundle_name%%[!.]*}"}
[ -n "$bundle_name" ] || bundle_name="Steam Game"
game_name_xml=$(printf '%s' "$game_name" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
loader_root="$HOME/Library/Application Support/notproton/launchers/$app_id"
mkdir -p "$loader_root"
loader_app="$loader_root/$bundle_name.app"
find "$loader_root" -maxdepth 1 -name '.build.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
loader_work=$(mktemp -d "$loader_root/.build.XXXXXX")
loader_stage="$loader_work/new/$bundle_name.app"
loader_contents="$loader_stage/Contents"
loader_macos="$loader_contents/MacOS"
loader_res="$loader_contents/Resources"
mkdir -p "$loader_macos" "$loader_res"

icon_arg=""
icon_root="$loader_root"
if resolve_icon && cp -f "$icon_cache" "$loader_res/game.icns"; then
  icon_arg="  <key>CFBundleIconFile</key><string>game</string>"
fi
[ -n "$icon_arg" ] || echo "no icon resolved, launching without one" >> "$log" 2>&1 || true

uielement_arg=""
if [ "${NOTPROTON_HIDE_LAUNCHER_TILE:-0}" = "1" ]; then
  uielement_arg="  <key>LSUIElement</key><true/>"
  echo "launcher tile hidden by NOTPROTON_HIDE_LAUNCHER_TILE" >> "$log" 2>&1 || true
fi
cat > "$loader_contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$game_name_xml</string>
  <key>CFBundleDisplayName</key><string>$game_name_xml</string>
  <key>CFBundleIdentifier</key><string>com.notproton.launcher.$app_id</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>This game would like to access your microphone.</string>
  <key>NSCameraUsageDescription</key><string>This game would like to access your camera.</string>
  <key>NSLocalNetworkUsageDescription</key><string>This game would like to access devices on your local network.</string>
$uielement_arg
$icon_arg
</dict>
</plist>
PLIST

# Invokes macOS Game Mode
for f in "$wine_unix"/*; do
  [ -e "$f" ] || continue
  base=${f##*/}
  case "$base" in
    wine|wine.app) continue ;;
  esac
  ln -sfn "$f" "$loader_macos/$base"
done
ln "$WINELOADER" "$loader_macos/wine" 2>/dev/null || cp "$WINELOADER" "$loader_macos/wine"
if [ -x "$loader_macos/wine" ]; then
  WINELOADER="$loader_app/Contents/MacOS/wine"
  echo "loader staged in bundle for game mode" >> "$log" 2>&1 || true
else
  echo "loader staging failed, game mode unavailable" >> "$log" 2>&1 || true
fi

cat > "$loader_macos/launcher" <<LAUNCHER
#!/bin/sh
export WINELOADER="$WINELOADER"
wine_log="$loader_root/notproton-wine.log"
exec > "\$wine_log" 2>&1
shim="$HOME/Library/Application Support/notproton/overlay-shim.dylib"
if [ -n "\$STEAM_DYLD_INSERT_LIBRARIES" ]; then
  if [ -f "\$shim" ]; then
    export DYLD_INSERT_LIBRARIES="\$shim:\$STEAM_DYLD_INSERT_LIBRARIES"
    export NOTPROTON_OVERLAY_SHIM="\$shim"
  else
    export DYLD_INSERT_LIBRARIES="\$STEAM_DYLD_INSERT_LIBRARIES"
  fi
fi
if [ -n "\$NOTPROTON_FEATURE_DYLIBS" ]; then
  export DYLD_INSERT_LIBRARIES="\${DYLD_INSERT_LIBRARIES:+\$DYLD_INSERT_LIBRARIES:}\$NOTPROTON_FEATURE_DYLIBS"
fi
[ -n "\$NOTPROTON_GAME_CWD" ] && cd "\$NOTPROTON_GAME_CWD"
"$WINELOADER" "\$@"
exit \$?
LAUNCHER
chmod +x "$loader_macos/launcher"

bundle_listing() {
  (cd "$1" && find . | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then
      printf 'l %s %s\n' "$p" "$(readlink "$p")"
    elif [ -d "$p" ]; then
      printf 'd %s\n' "$p"
    else
      printf 'f %s %s %s\n' "$p" "$(stat -f %Lp "$p")" "$(cksum < "$p")"
    fi
  done)
}
install_bundle() (
  exec 7>> "$loader_root/.lock"
  /usr/bin/lockf -s -t 30 7 || exit 1
  same=""
  for b in "$loader_root"/*.app; do
    if [ "$b" = "$loader_app" ] && [ -d "$b" ] && [ ! -L "$b" ] &&
       [ "$(bundle_listing "$b")" = "$(bundle_listing "$loader_stage")" ]; then
      same=1
    fi
  done
  if [ -n "$same" ]; then
    for b in "$loader_root"/*.app "$loader_root"/.[!.]*.app; do
      if [ "$b" != "$loader_app" ]; then rm -rf "$b" || true; fi
    done
    echo "launcher bundle unchanged" >> "$log" 2>&1 || true
  else
    stage_identity=$(stat -f '%d:%i' "$loader_stage") || exit 1
    loader_backup=$(mktemp -d "$loader_root/.backup.XXXXXX") || exit 1
    finish_bundle() {
      result=$?
      trap - EXIT
      trap '' HUP INT TERM
      installed_identity=$(stat -f '%d:%i' "$loader_app" 2>/dev/null) || installed_identity=""
      if [ "$installed_identity" != "$stage_identity" ]; then
        for saved in "$loader_backup"/* "$loader_backup"/.[!.]*; do
          [ -e "$saved" ] || [ -L "$saved" ] || continue
          mv "$saved" "$loader_root/${saved##*/}" || result=1
        done
        rmdir "$loader_backup" 2>/dev/null || result=1
      else
        rm -rf "$loader_backup" || true
      fi
      rm -rf "$loader_work" || true
      exit "$result"
    }
    trap 'finish_bundle' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for b in "$loader_root"/*.app "$loader_root"/.[!.]*.app "$loader_app"; do
      if [ -e "$b" ] || [ -L "$b" ]; then
        mv "$b" "$loader_backup/${b##*/}" || exit 1
      fi
    done
    mv "$loader_stage" "$loader_app" || exit 1
    echo "launcher bundle updated" >> "$log" 2>&1 || true
    finish_bundle
  fi
  rm -rf "$loader_work" || true
)
install_bundle

kill_wine_prefix() {
  "$WINESERVER" -k >> "$log" 2>&1 || true
  "$WINESERVER" -w >> "$log" 2>&1 || true
  if command -v lsof >/dev/null 2>&1 && server_dir=$(prefix_server_dir); then
    if [ -d "$server_dir" ]; then
      survivors=$(lsof -t +D "$server_dir" 2>/dev/null | sort -u)
      if [ -n "$survivors" ]; then
        echo "=== sweeping prefix stragglers: $survivors ===" >> "$log" 2>&1 || true
        # shellcheck disable=SC2086 # survivors is a list of pids and has to split
        kill -9 $survivors 2>/dev/null || true
      fi
    fi
  fi
}

# Steam's "Exit Game" and the client shutting the game down both send a
# termination signal to this run script, this handles it
# shellcheck disable=SC2329 # the trap below invokes this
terminate() {
  np_terminated=1
  echo "=== termination signal received, killing wine prefix ===" >> "$log" 2>&1 || true
  kill_wine_prefix
  [ -n "$open_pid" ] && kill "$open_pid" 2>/dev/null || true
  [ -n "$open_pid" ] || exit 143
}
open_pid=""
trap terminate TERM INT HUP

np_feat_dir="$np_support/plugins"
np_feat_log() {
  echo "=== $* ===" >> "$log" 2>&1 || true
}
np_feat_field() {
  LC_ALL=C sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p" "$1"
}
np_feat_first() {
  np_feat_field "$1" "$2" | head -1
}
np_feat_requires() {
  np_feat_field "$1" requires | head -n 4 | while IFS= read -r np_feat_req; do
    case "$np_feat_req" in
      (/*) ;;
      (*) np_feat_req="$HOME/$np_feat_req" ;;
    esac
    [ -f "$np_feat_req" ] && { printf '%s' "$np_feat_req"; break; }
  done
  return 0
}
np_feat_installed() {
  [ -z "$(np_feat_first "$1" requires)" ] || [ -n "$(np_feat_requires "$1")" ]
}
np_feat_file_of() {
  printf '%s\n' "$np_feat_list" | while IFS= read -r np_feat_entry; do
    [ "${np_feat_entry%% *}" = "$1" ] && { printf '%s' "${np_feat_entry#* }"; break; }
  done
  return 0
}
# webpatch.c skips files with overlong lines or values, so they're skipped here too.
np_feat_too_long() {
  LC_ALL=C awk 'length($0) >= 2047 { f = 1 } END { exit !f }' "$1" && return 0
  for np_feat_spec in key:192:1 label:192:1 description:512:1 section:32:1 on:32:1 \
                      off:32:1 depends:192:1 requires:192:4; do
    np_feat_max=${np_feat_spec#*:}
    np_feat_field "$1" "${np_feat_spec%%:*}" | head -n "${np_feat_spec##*:}" |
      LC_ALL=C awk -v m="${np_feat_max%:*}" 'length($0) >= m { f = 1 } END { exit !f }' &&
      return 0
  done
  return 1
}
np_feat_switched() {
  eval "np_feat_sv=\${$1-}"
  np_feat_son=$(np_feat_first "$2" on)
  # shellcheck disable=SC2154 # eval assigns np_feat_sv above
  [ "$np_feat_sv" = "${np_feat_son:-1}" ]
}
# Same rules as the panel.
np_feat_active() {
  [ "$2" -le 32 ] || return 1
  np_feat_af=$(np_feat_file_of "$1")
  [ -n "$np_feat_af" ] || return 1
  np_feat_switched "$1" "$np_feat_af" || return 1
  np_feat_installed "$np_feat_af" || return 1
  np_feat_adep=$(np_feat_first "$np_feat_af" depends)
  [ -z "$np_feat_adep" ] || np_feat_active "$np_feat_adep" $(($2 + 1))
}

np_feat_list=""
np_feat_count=0
# Same order as webpatch.c.
np_feat_files=$(printf '%s\n' "$np_feat_dir"/*.conf | LC_ALL=C sort)
while IFS= read -r np_feat_file; do
  case "$np_feat_file" in
    ("$np_feat_dir"/*.conf) ;;
    (*) continue ;;
  esac
  [ -f "$np_feat_file" ] && [ -r "$np_feat_file" ] || continue
  if np_feat_too_long "$np_feat_file"; then
    np_feat_log "plugins: $np_feat_file has a line or value that's too long, ignored"
    continue
  fi
  np_feat_key=$(np_feat_first "$np_feat_file" key)
  if [ -z "$np_feat_key" ]; then
    np_feat_log "plugins: $np_feat_file has no key, ignored"
    continue
  fi
  if ! printf '%s\n' "$np_feat_key" | LC_ALL=C grep -qx 'NOTPROTON_[A-Z0-9_]\{1,\}'; then
    np_feat_log "plugins: $np_feat_file has an invalid key $np_feat_key, ignored"
    continue
  fi
  if [ -z "$(np_feat_first "$np_feat_file" label)" ]; then
    np_feat_log "plugins: $np_feat_file has no label, ignored"
    continue
  fi
  case "$(np_feat_first "$np_feat_file" section)" in
    ("" | dev) ;;
    (*) np_feat_log "plugins: $np_feat_file is not in the dev section, ignored"; continue ;;
  esac
  if [ -n "$(np_feat_file_of "$np_feat_key")" ]; then
    np_feat_log "plugins: $np_feat_file repeats key $np_feat_key, ignored"
    continue
  fi
  if [ "$np_feat_count" -ge 32 ]; then
    np_feat_log "plugins: $np_feat_file is over the 32 plugin limit, ignored"
    continue
  fi
  np_feat_count=$((np_feat_count + 1))
  np_feat_list="$np_feat_list
$np_feat_key $np_feat_file"
done <<NP_FEAT_FILES
$np_feat_files
NP_FEAT_FILES

np_feat_dylibs=""
np_feat_envs=""
while IFS= read -r np_feat_entry; do
  [ -n "$np_feat_entry" ] || continue
  np_feat_key=${np_feat_entry%% *}
  np_feat_file=${np_feat_entry#* }
  if ! np_feat_installed "$np_feat_file"; then
    np_feat_switched "$np_feat_key" "$np_feat_file" &&
      np_feat_log "$np_feat_key is on but is skipped as $np_feat_key's required files are missing"
    continue
  fi
  np_feat_active "$np_feat_key" 0 || continue

  if [ "$(np_feat_first "$np_feat_file" inject)" = 1 ]; then
    np_feat_lib=$(np_feat_requires "$np_feat_file")
    if [ ! -f "$np_feat_lib" ]; then
      np_feat_log "$np_feat_key is skipped as it asks to load a dylib but doesn't name one"
    elif [ "${np_feat_lib#*:}" != "$np_feat_lib" ]; then
      np_feat_log "$np_feat_key is skipped as $np_feat_lib has a colon in it"
    else
      case ":$np_feat_dylibs:" in
        (*":$np_feat_lib:"*) ;;
        (*) np_feat_dylibs="${np_feat_dylibs:+$np_feat_dylibs:}$np_feat_lib"
            np_feat_log "$np_feat_key will be loaded from $np_feat_lib" ;;
      esac
    fi
  fi

  np_feat_stage=$(np_feat_first "$np_feat_file" stage)
  if [ -n "$np_feat_stage" ]; then
    case "$np_feat_stage" in
      (/*) ;;
      (*) np_feat_stage="$HOME/$np_feat_stage" ;;
    esac
    np_feat_sys32="$WINEPREFIX/drive_c/windows/system32"
    if [ ! -d "$np_feat_stage" ]; then
      np_feat_log "$np_feat_key copies no DLLs as $np_feat_stage doesn't exist"
    elif [ ! -d "$np_feat_sys32" ]; then
      np_feat_log "$np_feat_key copies no DLLs as the prefix has no system32"
    else
      for np_feat_src in "$np_feat_stage"/*; do
        [ -f "$np_feat_src" ] || continue
        np_feat_dst="$np_feat_sys32/$(basename "$np_feat_src")"
        if [ -d "$np_feat_dst" ]; then
          np_feat_log "$np_feat_key skips $(basename "$np_feat_src") as system32 has a folder by that name"
          continue
        fi
        cmp -s "$np_feat_src" "$np_feat_dst" && continue
        np_feat_tmp="$np_feat_dst.np-stage.$$"
        rm -f "$np_feat_tmp"
        if { cp -c "$np_feat_src" "$np_feat_tmp" 2>/dev/null \
             || cp "$np_feat_src" "$np_feat_tmp"; } && mv -f "$np_feat_tmp" "$np_feat_dst"; then
          np_feat_log "$np_feat_key copied $(basename "$np_feat_src") into system32"
        else
          rm -f "$np_feat_tmp"
          np_feat_log "$np_feat_key failed to copy $(basename "$np_feat_src") into system32"
        fi
      done
    fi
  fi

  np_feat_over=$(np_feat_first "$np_feat_file" overrides)
  if [ -n "$np_feat_over" ]; then
    export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}$np_feat_over"
    np_feat_log "$np_feat_key adds overrides $np_feat_over"
  fi

  while IFS= read -r np_feat_env; do
    [ -n "$np_feat_env" ] || continue
    case "$np_feat_env" in
      (*=*) ;;
      (*) np_feat_log "$np_feat_key skips env line $np_feat_env as it has no ="; continue ;;
    esac
    if ! printf '%s\n' "${np_feat_env%%=*}" | LC_ALL=C grep -qx '[A-Z_][A-Z0-9_]*'; then
      np_feat_log "$np_feat_key skips env ${np_feat_env%%=*} as it isn't a valid variable name"
      continue
    fi
    case "${np_feat_env%%=*}" in
      (DYLD_* | PATH | CX_ROOT | CX_HOME | WINE* | STEAM_COMPAT_* | STEAM_DYLD_INSERT_LIBRARIES | \
       NOTPROTON_FEATURE_DYLIBS | NOTPROTON_GAME_CWD | NOTPROTON_OVERLAY_SHIM)
        np_feat_log "$np_feat_key skips env ${np_feat_env%%=*} as the compat_run script sets it"
        continue ;;
    esac
    np_feat_rest=${np_feat_env#*=}
    # shellcheck disable=SC2088 # a literal tilde is what is being matched
    case "$np_feat_rest" in
      ("~/"*) np_feat_rest="\$HOME/${np_feat_rest#"~/"}" ;;
    esac
    np_feat_env="${np_feat_env%%=*}="
    # shellcheck disable=SC2016 # the literal text $HOME is what is being replaced
    while :; do
      case "$np_feat_rest" in
        (*'$HOME'*)
          np_feat_env="$np_feat_env${np_feat_rest%%'$HOME'*}$HOME"
          np_feat_rest=${np_feat_rest#*'$HOME'} ;;
        (*) np_feat_env="$np_feat_env$np_feat_rest"; break ;;
      esac
    done
    # Kept in reverse since they get prepended to open args (which flips the order)
    np_feat_envs="$np_feat_env
$np_feat_envs"
    np_feat_log "$np_feat_key sets $np_feat_env"
  done <<NP_FEAT_ENV
$(np_feat_field "$np_feat_file" env)
NP_FEAT_ENV
done <<NP_FEAT_LIST
$np_feat_list
NP_FEAT_LIST

game_cwd="$(pwd)"
if [ -n "$STEAM_DYLD_INSERT_LIBRARIES" ]; then
  echo "=== overlay injected from $STEAM_DYLD_INSERT_LIBRARIES ===" >> "$log" 2>&1 || true
else
  echo "=== client staged no overlay renderer, overlay disabled ===" >> "$log" 2>&1 || true
fi
set -- --args "$shim_exe" "$@"
# Prepended first so they end up last among the --env args since open keeps the last of a repeated name.
while IFS= read -r np_feat_env; do
  [ -n "$np_feat_env" ] && set -- --env "$np_feat_env" "$@"
done <<NP_FEAT_ENVS
$np_feat_envs
NP_FEAT_ENVS
for name in $(env | LC_ALL=C sed -nE 's/^(CX_APPLEGPTK_LIBD3DSHARED_PATH|Steam[A-Za-z0-9]*|(CX_GRAPHICS|D3DM_|DXMT_|DXVK_|FEX_|MTL_|ROSETTA_)[A-Z0-9_]*)=.*/\1/p'); do
  eval "value=\$$name"
  # shellcheck disable=SC2154 # eval assigns value on the line above
  set -- --env "$name=$value" "$@"
done

# Anything this script does not know by name. A launch option NOTPROTON_ENV_FOO=bar gives
# the game FOO=bar, which is the only per-game way to set one, and Wine and the graphics
# layers take far more than the prefixes above.
np_env_passed=$(env | LC_ALL=C sed -nE 's/^NOTPROTON_ENV_([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' \
  | LC_ALL=C sort)
for name in $np_env_passed; do
  case "$name" in
    (DYLD_* | PATH | HOME | CX_ROOT | CX_HOME | STEAM_COMPAT_* | STEAM_DYLD_INSERT_LIBRARIES | \
     WINEPREFIX | WINELOADER | WINESERVER | WINEDLLPATH | WINEDLLOVERRIDES | WINEMSYNC | NOTPROTON_*)
      echo "=== NOTPROTON_ENV_$name would replace a setting this launch sets itself, ignored ===" \
        >> "$log" 2>&1 || true
      continue ;;
  esac
  eval "value=\$NOTPROTON_ENV_$name"
  set -- --env "$name=$value" "$@"
  echo "=== NOTPROTON_ENV_$name sets $name ===" >> "$log" 2>&1 || true
done
set -- \
  --env CX_ROOT="$CX_ROOT" \
  --env CX_HOME="$CX_HOME" \
  --env WINESERVER="$WINESERVER" \
  --env WINEDLLPATH="$WINEDLLPATH" \
  --env WINEDLLOVERRIDES="$WINEDLLOVERRIDES" \
  --env WINEMSYNC="$WINEMSYNC" \
  --env WINEPREFIX="$WINEPREFIX" \
  --env WINEDEBUG="$WINEDEBUG" \
  --env PATH="$PATH" \
  --env STEAM_COMPAT_DATA_PATH="$STEAM_COMPAT_DATA_PATH" \
  --env STEAM_COMPAT_INSTALL_PATH="$STEAM_COMPAT_INSTALL_PATH" \
  --env STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_COMPAT_CLIENT_INSTALL_PATH" \
  --env STEAM_COMPAT_APP_ID="$STEAM_COMPAT_APP_ID" \
  --env STEAM_DYLD_INSERT_LIBRARIES="$STEAM_DYLD_INSERT_LIBRARIES" \
  --env NOTPROTON_FEATURE_DYLIBS="$np_feat_dylibs" \
  --env NOTPROTON_GAME_CWD="$game_cwd" "$@"
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A"
lsregister="$lsregister/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$lsregister" ] && "$lsregister" -f "$loader_app" >> "$log" 2>&1 || true
np_started=$(date +%s)
np_terminated=0
open -n -W -a "$loader_app" "$@" >> "$log" 2>&1 &
open_pid=$!
/usr/bin/caffeinate -d -i -w "$open_pid" >> "$log" 2>&1 &
status=0
wait "$open_pid" || status=$?
echo "=== game exited status=$status, killing wine prefix ===" >> "$log" 2>&1 || true
kill_wine_prefix
[ -z "$STEAM_COMPAT_DATA_PATH" ] \
  || record_session "$loader_root/notproton-wine.log" "$(($(date +%s) - np_started))" "$np_terminated"
echo "=== wine prefix killed, session ending ===" >> "$log" 2>&1 || true
exit $status
