#!/bin/sh
# notproton CrossOver compatibility tool shim
set -e

verb="$1"
shift || true

# hook_launch.c passes the launch options through a shell before this script runs, matching
# Linux Steam. A NAME=value option placed ahead of %command% is an environment variable,
# and anything after %command% is a launch argument passed to the game.
# Options saved before the panel wrote %command% arrive after the game instead of ahead of it.
launch_env=""
argc=$#
argi=0
while [ "$argi" -lt "$argc" ]; do
  arg="$1"
  shift
  case "$arg" in
    CX_GRAPHICS*=*|D3DM_*=*|DXMT_*=*|DXVK_*=*|MTL_*=*|NOTPROTON_*=*|ROSETTA_*=*|WINE*=*)
      # shellcheck disable=SC2163 # arg is a NAME=VALUE pair, which export takes as an assignment
      export "$arg"
      launch_env="$launch_env $arg"
      ;;
    *) set -- "$@" "$arg" ;;
  esac
  argi=$((argi + 1))
done
launch_args="$*"

case "$verb" in
  getcompatpath)
    printf '%s\n' "$STEAM_COMPAT_DATA_PATH"
    exit 0
    ;;
esac

np_support="$HOME/Library/Application Support/notproton"
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

wine_unix="$CX_ROOT/lib/wine/aarch64-unix"
WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
WINESERVER="$CX_ROOT/CrossOver-Hosted Application/wineserver-arm64"
if [ "$np_flavor" = rosetta ] || [ ! -x "$WINELOADER" ] || [ ! -x "$WINESERVER" ]; then
  wine_unix="$CX_ROOT/lib/wine/x86_64-unix"
  WINELOADER="$wine_unix/wine"
  WINESERVER="$CX_ROOT/CrossOver-Hosted Application/wineserver"
  [ -x "$WINESERVER" ] || WINESERVER="$CX_ROOT/CrossOver-Hosted Application/wineserver-x86"
fi
export WINELOADER WINESERVER
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
  echo "args:"; for a in "$@"; do echo "  [$a]"; done
  echo "cwd=$(pwd)"
  echo "STEAM_COMPAT_DATA_PATH=$STEAM_COMPAT_DATA_PATH"
  echo "STEAM_COMPAT_INSTALL_PATH=$STEAM_COMPAT_INSTALL_PATH"
  echo "STEAM_COMPAT_APP_ID=$STEAM_COMPAT_APP_ID"
  echo "-- steam env passed through --"
  env | grep -iE '^(Steam|SDL_)' | sort
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

# Steam does not set SteamAppId or SteamGameId for helpers like the install-script
# evaluator. If they are set, SteamAPI_Init registers the helper as the running game so the
# real launch fails with AppError_16. Not applicable to non-Steam shortcuts, which come in
# as waitforexitandrun.
case "$verb" in
  waitforexitandrun)
    [ -n "$SteamAppId" ] || export SteamAppId="$app_id"
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
    aa64) printf 'the FEX build of CrossOver' ;;
    8664) printf 'the Rosetta build of CrossOver' ;;
    *) printf 'an older 32-bit setup' ;;
  esac
}

# Steam passes "run" for helpers such as install scripts, which get no dialog.
show_alert() {
  [ "$verb" != run ] || return 0
  osascript >/dev/null 2>&1 <<APPLESCRIPT || true
display alert "$1" message "$2" as critical
APPLESCRIPT
}

# A quote or backslash in the text would end the AppleScript string early.
alert_safe() {
  # shellcheck disable=SC1003 # the pair deletes a literal backslash, not a quote
  printf '%s' "$1" | tr -d '"\\'
}

refuse_foreign_prefix() {
  case "${wine_unix##*/}" in
    aarch64-unix) want=aa64 ;;
    *) want=8664 ;;
  esac
  have=$(prefix_machine) || return 0
  [ "$have" = "$want" ] && return 0
  echo "=== prefix ntdll is $have and this compatibility tool wants $want, rebuild the prefix in NotProton ===" >> "$log" 2>&1 || true
  show_alert "This game needs its prefix rebuilt" "This game originally ran under $(tool_name "$have"), but $(tool_name "$want") is present now. The prefix needs to be rebuilt in NotProton in order to run the game. You will not lose game saves by rebuilding the prefix."
  exit 1
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

refuse_other_build() {
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
    echo "=== prefix was last run by build $had_build and this compatibility tool runs $np_build, rebuild the prefix in NotProton ===" >> "$log" 2>&1 || true
    had_display=$(alert_safe "${had_display:-CrossOver build $had_build}")
    show_alert "This game needs its prefix rebuilt" "This game's prefix was last run by $had_display, and this compatibility tool runs $(alert_safe "$np_display"). Rebuild the prefix in NotProton to run it here, or pick $had_display again in the game's Compatibility settings. You will not lose game saves by rebuilding the prefix."
    exit 1
  fi
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
    if [ -L "$dst_dir" ] && [ ! -e "$dst_dir" ]; then
      rm -f "$dst_dir" 2>/dev/null || true
    fi
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
    if [ -n "$rest" ] && [ -e "$dst_dir" ]; then continue; fi
    if ! mkdir -p "$dst_dir" 2>/dev/null; then failed=1; continue; fi
    for entry in "$src_dir"/* "$src_dir"/.[!.]* "$src_dir"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=${entry##*/}
      if [ -d "$entry" ] && [ ! -L "$entry" ]; then
        set -- "$@" "$rest/$name"
        continue
      fi
      landing="$dst_dir/$name"
      if [ -e "$landing" ]; then continue; fi
      if [ -L "$landing" ]; then rm -f "$landing" 2>/dev/null || true; fi
      if [ -L "$entry" ]; then
        if ! cp -Pp "$entry" "$landing" 2>/dev/null; then
          rm -f "$landing" 2>/dev/null || true
          failed=1
        fi
      else
        if ! cp -p "$entry" "$landing" 2>/dev/null; then
          rm -f "$landing" 2>/dev/null || true
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
      continue
    fi
    if [ -e "$old" ] && [ ! -L "$old" ]; then
      if ! merge_user_dir "$old" "$new"; then
        echo "=== $old_rel did not merge into $new_rel, left in place ===" \
          >> "$log" 2>&1 || true
        continue
      fi
      rmdir "$old BACKUP" 2>/dev/null || true
      if [ -e "$old BACKUP" ] || [ -L "$old BACKUP" ] \
        || ! mv "$old" "$old BACKUP" 2>> "$log"; then
        echo "=== $old_rel could not be moved aside, cloud saves stay split ===" \
          >> "$log" 2>&1 || true
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
  migrate_user_paths "$profile"
  if [ -L "$users/crossover" ] && [ ! -e "$users/crossover" ]; then
    rm -f "$users/crossover" 2>/dev/null || true
  fi
  if [ ! -e "$users/crossover" ] \
    && ln -s steamuser "$users/crossover" 2>/dev/null; then
    echo "=== pointed crossover at steamuser ===" >> "$log" 2>&1 || true
  fi
}

import_prefix_settings() {
  if [ "$NOTPROTON_RETINA" = "1" ]; then
    retina_line='"RetinaMode"="y"'
  else
    retina_line='"RetinaMode"=-'
  fi
  settings_file=$(mktemp "$WINEPREFIX/drive_c/notproton-settings.XXXXXX" 2>/dev/null) \
    || settings_file=""
  if [ -z "$settings_file" ] || ! printf '%s\r\n' \
      'Windows Registry Editor Version 5.00' '' \
      '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
      '[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
      '[HKEY_CURRENT_USER\Software\Wine\WineDbg]' '"ShowCrashDialog"=dword:00000000' '' \
      '[HKEY_CURRENT_USER\Software\Wine\Mac Driver]' "$retina_line" '' \
      '[HKEY_LOCAL_MACHINE\Software\Classes\steam]' '"URL Protocol"=""' '' \
      '[HKEY_LOCAL_MACHINE\Software\Classes\steam\shell\open\command]' \
      '@="\"C:\\Program Files (x86)\\Steam\\steam.exe\" \"%1\""' '' \
      > "$settings_file" 2>/dev/null; then
    [ -z "$settings_file" ] || rm -f "$settings_file"
    echo "=== could not write the prefix settings, launching without them ===" >> "$log" 2>&1 || true
    # the bridge staging still needs a built prefix
    "$WINELOADER" wineboot --init >> "$log" 2>&1 || true
    return 0
  fi
  "$WINELOADER" reg import "C:\\${settings_file##*/}" >> "$log" 2>&1 \
    && import_status=0 || import_status=$?
  rm -f "$settings_file"
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

# A fresh prefix is close to a gigabyte of files that wineboot copies out of the
# runner, and every game gets its own. Build one template per runner instead and seed
# each game from it. Within a single APFS volume "cp -c" clones, so the files share
# blocks and every prefix after the first costs almost nothing, as well as skipping
# the wineboot that building one needs. Seeding this way is safe because a wine prefix
# does not care where it lives: dosdevices holds "c: -> ../drive_c" and "z: -> /",
# which both survive the move, and the template is built through the same steps in the
# same order a game's prefix takes.
template_root="$np_support/templates"
# Keyed by the build this compatibility tool runs and by the unix arch. A build can be
# installed alongside others, and one runner serves both flavors, which populate a
# prefix from different PE sets, so both belong in the key.
runner_id=""
if [ -n "$np_build" ]; then
  runner_id="crossover-$np_build-${wine_unix##*/}"
fi
template="$template_root/$runner_id/pfx"

# A clone only shares blocks inside one volume, and a library can sit on a disk of its
# own, so the template belongs beside the prefixes it seeds. compatdata is where those
# prefixes already live, so it is always the right volume. The support directory stays
# as the fallback for a run with no library path to derive one from.
pick_template_dir() {
  if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
    template_root="$(dirname "$STEAM_COMPAT_DATA_PATH")/notproton-template"
  fi
  template="$template_root/$runner_id/pfx"
}

same_volume() {
  one=$(stat -f %d "$1" 2>/dev/null) || return 1
  two=$(stat -f %d "$2" 2>/dev/null) || return 1
  [ "$one" = "$two" ]
}

# Built under a temporary name and moved into place, so a second game starting
# while this runs sees either no template or a finished one, never a partial tree.
build_prefix_template() {
  staging="$template_root/$runner_id/pfx.building.$$"
  rm -rf "$staging" 2>/dev/null || true
  mkdir -p "$staging" || return 1
  echo "=== building the prefix template for $runner_id ===" >> "$log" 2>&1 || true
  # Through the same steps a game's prefix takes, in the same order. A bare wineboot
  # leaves a real users/crossover directory behind, which lay_out_proton_profile
  # refuses to convert, so a prefix seeded from such a template would lose the
  # steamuser layout that cloud saves are written through.
  lay_out_proton_profile "$staging"
  WINEPREFIX="$staging" "$WINELOADER" wineboot --init >> "$log" 2>&1 || true
  WINEPREFIX="$staging" "$WINESERVER" -w >> "$log" 2>&1 || true
  if [ ! -f "$staging/system.reg" ]; then
    echo "=== wineboot produced no template, this game gets its own prefix ===" \
      >> "$log" 2>&1 || true
    rm -rf "$staging" 2>/dev/null || true
    return 1
  fi
  if [ -f "$template/system.reg" ]; then
    rm -rf "$staging" 2>/dev/null || true
  else
    mv "$staging" "$template" 2>/dev/null || rm -rf "$staging" 2>/dev/null || true
  fi
  [ -f "$template/system.reg" ]
}

seed_prefix_from_template() {
  if [ -z "$runner_id" ] || [ -f "$WINEPREFIX/system.reg" ]; then
    return 0
  fi
  pick_template_dir
  if [ ! -f "$template/system.reg" ] && ! build_prefix_template; then
    return 0
  fi

  if same_volume "$template" "$WINEPREFIX" \
    && cp -c -R "$template/." "$WINEPREFIX/" 2>/dev/null; then
    echo "=== cloned this prefix from the $runner_id template ===" >> "$log" 2>&1 || true
  elif cp -R "$template/." "$WINEPREFIX/" 2>/dev/null; then
    echo "=== copied this prefix from the $runner_id template, not a clone ===" \
      >> "$log" 2>&1 || true
  else
    echo "=== could not seed from the template, it will be built from scratch ===" \
      >> "$log" 2>&1 || true
  fi
}

if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
  export WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  mkdir -p "$WINEPREFIX"
  msync_from=environment
  if [ -z "$WINEMSYNC" ] && [ -r "$STEAM_COMPAT_DATA_PATH/notproton-msync" ]; then
    WINEMSYNC=$(tr -d ' \t\n' \
      < "$STEAM_COMPAT_DATA_PATH/notproton-msync" 2>/dev/null || true)
    msync_from=carried-over
  fi
  [ -n "$WINEMSYNC" ] || msync_from=default
  export WINEMSYNC="${WINEMSYNC:-0}"
  printf '%s' "$WINEMSYNC" \
    > "$STEAM_COMPAT_DATA_PATH/notproton-msync" 2>/dev/null || true
  stage_step="prefix build check"
  refuse_other_build
  stage_step="prefix arch check"
  refuse_foreign_prefix
  claim_prefix
  echo "sync: WINEMSYNC=$WINEMSYNC from $msync_from" >> "$log" 2>&1 || true
  "$WINESERVER" -k >> "$log" 2>&1 || true
  stage_step="prefix seed"
  seed_prefix_from_template
  stage_step="profile layout"
  lay_out_proton_profile
  echo "video: RetinaMode=${NOTPROTON_RETINA:-0}" >> "$log" 2>&1 || true
  stage_step="prefix settings"
  import_prefix_settings
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
  if cp -f "$src" "$dst"; then
    echo "=== installed syswow64 lsteamclient trigger ===" >> "$log" 2>&1 || true
  else
    echo "=== could not install the syswow64 lsteamclient trigger ===" >> "$log" 2>&1 || true
  fi
}

# A fix to match Proton
install_legacy_steam_dll() {
  src="$bridge_src/legacycompat/Steam.dll"
  dst="$WINEPREFIX/drive_c/windows/syswow64/Steam.dll"
  [ -f "$src" ] && [ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || return 0
  cmp -s "$src" "$dst" && return 0
  if cp -f "$src" "$dst"; then
    echo "=== installed legacy Steam.dll ===" >> "$log" 2>&1 || true
  else
    echo "=== could not install the legacy Steam.dll ===" >> "$log" 2>&1 || true
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
    cp -f "$f" "$dst/$b" && \
      echo "=== installed legacycompat/$b ===" >> "$log" 2>&1
  done
}

bridge_files="steamclient64.dll steamclient.dll tier0_s64.dll vstdlib_s64.dll"
bridge_files="$bridge_files lsteamclient.dll steam.exe"
if [ -d "$bridge_src" ] && [ -n "$WINEPREFIX" ]; then
  stage_step="bridge staging"
  mkdir -p "$prefix_steam"
  # shellcheck disable=SC2086 # the list is ours and has no spaces
  src_stamp=$(cd "$bridge_src" && stat -f '%z %m' $bridge_files 2>/dev/null) || true
  # shellcheck disable=SC2086
  dst_stamp=$(cd "$prefix_steam" && stat -f '%z %m' $bridge_files 2>/dev/null) || true
  if [ -n "$src_stamp" ] && [ "$src_stamp" = "$dst_stamp" ]; then
    echo "=== bridge already staged ===" >> "$log" 2>&1 || true
  else
    for f in $bridge_files; do
      src="$bridge_src/$f"
      if [ ! -f "$src" ]; then
        echo "=== bridge missing $f ===" >> "$log" 2>&1 || true
        continue
      fi
      cp -fp "$src" "$prefix_steam/$f" || \
        echo "=== failed to stage $f ===" >> "$log" 2>&1
    done
  fi
  for f in "$prefix_steam"/*.dll "$prefix_steam"/*.so "$prefix_steam"/*.exe; do
    [ -f "$f" ] || continue
    case " $bridge_files " in
      *" $(basename "$f") "*) ;;
      *) rm -f "$f" && echo "=== pruned stale $(basename "$f") ===" >> "$log" 2>&1 ;;
    esac
  done
  verify_runner
  install_lsteamclient_trigger
  install_legacy_steam_dll
  export WINEDLLPATH="$prefix_steam:$WINEDLLPATH"
  # If the same DLL appears twice in WINEDLLOVERRIDES, the last entry wins.
  export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}steamclient=n;steamclient64=n;lsteamclient=b"
  native_client="$STEAM_COMPAT_CLIENT_INSTALL_PATH"
  if [ -z "$native_client" ]; then
    native_client="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$native_client"
  fi
  install_legacycompat
  echo "=== bridge staged into $prefix_steam ===" >> "$log" 2>&1 || true
  echo "WINEDLLPATH=$WINEDLLPATH" >> "$log" 2>&1 || true
  echo "WINEDLLOVERRIDES=$WINEDLLOVERRIDES" >> "$log" 2>&1 || true
  echo "STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAM_COMPAT_CLIENT_INSTALL_PATH" >> "$log" 2>&1 || true
fi

export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all}"
trap - EXIT
echo "launch_args=$launch_args" >> "$log" 2>&1 || true
[ -z "$launch_env" ] || echo "launch_env=$launch_env" >> "$log" 2>&1 || true
echo "=== launching ($verb): $WINELOADER $* ===" >> "$log" 2>&1 || true

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
client_root="$STEAM_COMPAT_CLIENT_INSTALL_PATH"
while [ -n "$client_root" ] && [ "$client_root" != "/" ] && [ ! -d "$client_root/appcache" ]; do
  client_root=$(dirname "$client_root")
done
# Icon stuff
appinfo_tool="$HOME/Library/Application Support/notproton/appinfo"
appinfo_vdf="$client_root/appcache/appinfo.vdf"
meta_name=""
meta_icon=""
meta_clienticon=""
if [ -x "$appinfo_tool" ] && [ -f "$appinfo_vdf" ]; then
  meta=$("$appinfo_tool" "$appinfo_vdf" "$app_id" 2>> "$log") || meta=""
  meta_name=$(printf '%s\n' "$meta" | sed -n 's/^name=//p')
  meta_icon=$(printf '%s\n' "$meta" | sed -n 's/^icon=//p')
  meta_clienticon=$(printf '%s\n' "$meta" | sed -n 's/^clienticon=//p')
fi
game_name="$meta_name"
if [ -z "$game_name" ] && [ -f "$manifest" ]; then
  game_name=$(sed -n 's/.*"name"[[:space:]]*"\(.*\)".*/\1/p' "$manifest" | head -1)
fi
[ -z "$game_name" ] && game_name=$(basename "$STEAM_COMPAT_INSTALL_PATH")
[ -z "$game_name" ] && game_name="Steam Game"
# shellcheck disable=SC1003 # the pair deletes a literal backslash, not a quote
bundle_name=$(printf '%s' "$game_name" | tr -d '/:"`$\\')
game_name_xml=$(printf '%s' "$game_name" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
loader_root="$HOME/Library/Application Support/notproton/launchers/$app_id"
mkdir -p "$loader_root"
loader_app="$loader_root/$bundle_name.app"
rm -rf "$loader_root"/*.app
loader_contents="$loader_app/Contents"
loader_macos="$loader_contents/MacOS"
loader_res="$loader_contents/Resources"
mkdir -p "$loader_macos" "$loader_res"

icon_arg=""
resolve_icon() {
  set +e
  iconmaker="$HOME/Library/Application Support/notproton/iconmaker"
  art_dir="$client_root/appcache/librarycache/$app_id"
  art=""
  if [ -n "$meta_clienticon" ]; then
    ico="$loader_root/clienticon-$meta_clienticon.ico"
    absent="$loader_root/clienticon-$meta_clienticon.absent"
    failed="$loader_root/clienticon-$meta_clienticon.failed"
    find "$loader_root" -maxdepth 1 -name 'clienticon-*'   ! -name "clienticon-$meta_clienticon.*" -delete 2>/dev/null || true
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
  icon_cache="$loader_root/game.icns"
  if [ -n "$art" ] && [ -s "$icon_cache" ] &&   [ "$(cat "$loader_root/notproton-icon.source" 2>/dev/null)" =   "$icon_source" ] && cp -f "$icon_cache" "$loader_res/game.icns"; then
    icon_arg="  <key>CFBundleIconFile</key><string>game</string>"
    echo "icon reused from $art" >> "$log" 2>&1 || true
  elif [ -n "$art" ] && [ -x "$iconmaker" ]; then
    if "$iconmaker" "$art" "$icon_cache" >> "$log" 2>&1 &&   cp -f "$icon_cache" "$loader_res/game.icns"; then
      icon_arg="  <key>CFBundleIconFile</key><string>game</string>"
      printf '%s\n' "$icon_source" > "$loader_root/notproton-icon.source"
      echo "icon built from $art" >> "$log" 2>&1 || true
    elif [ "$art" = "$ico" ]; then
      # A cached .ico that iconmaker rejects is corrupt and passes the size
      # guard on every launch, so drop it to force a clean fetch next time.
      rm -f "$ico"
      echo "discarded unreadable client icon $meta_clienticon" >> "$log" 2>&1 || true
    fi
  fi
  set -e
  return 0
}
resolve_icon || true
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
  WINELOADER="$loader_macos/wine"
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
[ -n "\$NOTPROTON_GAME_CWD" ] && cd "\$NOTPROTON_GAME_CWD"
"$WINELOADER" "\$@"
exit \$?
LAUNCHER
chmod +x "$loader_macos/launcher"

wine_helpers='winedevice\.exe|services\.exe|plugplay\.exe|svchost\.exe'
wine_helpers="$wine_helpers|rpcss\.exe|explorer\.exe|steam\.exe"
wine_helpers="$wine_helpers|winemenubuilder\.exe|conhost\.exe|start\.exe"
wine_helpers="$wine_helpers|wineboot\.exe|rundll32\.exe|tabtip\.exe"
wine_helpers="$wine_helpers|vc_redist|vcredist|dxsetup\.exe|msiexec\.exe"
wine_helpers="$wine_helpers|installinf|iscriptevaluator\.exe|regsvr32\.exe"
wine_helpers="$wine_helpers|winedbg\.exe|unitycrashhandler"
prefix_server_dir() {
  [ -n "$WINEPREFIX" ] || return 1
  ids=$(stat -f '%d-%i' "$WINEPREFIX" 2>/dev/null) || return 1
  [ -n "$ids" ] || return 1
  printf '/tmp/.wine-%s/server-%s' "$(id -u)" \
    "$(printf '%s' "$ids" | awk -F- '{printf "%x-%x", $1, $2}')"
}

prefix_game_running() {
  command -v lsof >/dev/null 2>&1 || return 1
  dir=$(prefix_server_dir) || return 1
  [ -d "$dir" ] || return 1
  pids=$(lsof -t +D "$dir" 2>/dev/null | sort -u | tr '\n' ',')
  pids=${pids%,}
  [ -n "$pids" ] || return 1
  # shellcheck disable=SC1003 # the pair matches the backslash in a drive path
  ps -p "$pids" -o args= 2>/dev/null | grep -E '^[A-Za-z]:\\' | grep -viE "$wine_helpers" | grep -q .
}

wait_prefix_idle() {
  idle=0
  tick=0
  while [ "$idle" -lt 10 ] && [ "$tick" -lt 300 ]; do
    tick=$((tick + 1))
    if prefix_game_running; then idle=0; else idle=$((idle + 1)); fi
    sleep 1
  done
  echo "wait_prefix_idle done after tick=$tick idle=$idle" >> "$log" 2>&1 || true
}

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
  echo "=== termination signal received, killing wine prefix ===" >> "$log" 2>&1 || true
  kill_wine_prefix
  [ -n "$open_pid" ] && kill "$open_pid" 2>/dev/null || true
}
trap terminate TERM INT HUP

game_cwd="$(pwd)"
if [ -n "$STEAM_DYLD_INSERT_LIBRARIES" ]; then
  echo "=== overlay injected from $STEAM_DYLD_INSERT_LIBRARIES ===" >> "$log" 2>&1 || true
else
  echo "=== client staged no overlay renderer, overlay disabled ===" >> "$log" 2>&1 || true
fi
set -- --args "$shim_exe" "$@"
for name in $(env | sed -nE 's/^(Steam[A-Za-z0-9]*|(CX_GRAPHICS|D3DM_|DXMT_|DXVK_|MTL_|ROSETTA_)[A-Z0-9_]*)=.*/\1/p'); do
  eval "value=\$$name"
  # shellcheck disable=SC2154 # eval assigns value on the line above
  set -- --env "$name=$value" "$@"
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
  --env NOTPROTON_GAME_CWD="$game_cwd" "$@"
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A"
lsregister="$lsregister/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$lsregister" ] && "$lsregister" -f "$loader_app" >> "$log" 2>&1 || true
open -n -W -a "$loader_app" "$@" >> "$log" 2>&1 &
open_pid=$!
status=0
seen=0
idle=0
while :; do
  if prefix_game_running; then
    seen=1
    idle=0
  else
    idle=$((idle + 1))
  fi
  if ! kill -0 "$open_pid" 2>/dev/null; then
    wait "$open_pid" || status=$?
    echo "=== bundle exited status=$status ===" >> "$log" 2>&1 || true
    if [ "$status" -le 128 ]; then
      wait_prefix_idle
    fi
    break
  fi
  if [ "$seen" -eq 1 ] && [ "$idle" -ge 10 ]; then
    echo "=== game tree gone, ending session ===" >> "$log" 2>&1 || true
    break
  fi
  sleep 1
done
echo "=== game exited status=$status, killing wine prefix ===" >> "$log" 2>&1 || true
kill_wine_prefix
echo "=== wine prefix killed, session ending ===" >> "$log" 2>&1 || true
exit $status
