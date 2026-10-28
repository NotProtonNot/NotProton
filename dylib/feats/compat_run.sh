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
# The folder's name is the tool's name, which is what a plugin's "tools" is matched against.
np_tool_name=$(basename -- "${np_tool_dir:-.}")
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
if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
  log="$STEAM_COMPAT_DATA_PATH/notproton-run.log"
else
  log=/dev/null
fi
[ "$(stat -f %z "$log" 2>/dev/null || echo 0)" -gt 262144 ] \
  && : > "$log" || true
# Plugin and variant descriptors, normalised exactly as dylib/feats/conf.c does, so the
# panel and the launch agree on every file: one "id<TAB>field<TAB>value" line per field
# in the order read, "!<TAB>scope<TAB>code[:detail]" where one was refused, and a
# "== <path>" line as each file is opened.
np_conf_normalise() (
  np_conf_dir=$1
  np_conf_shown=$2
  np_conf_kind=$3
  # Byte order, which is the order webpatch.c reads them in. A name carrying a tab or a
  # newline is skipped rather than normalised: either would break the lines below.
  np_conf_names=$(
    for np_conf_file in "$np_conf_dir"/*.conf; do
      case ${np_conf_file##*/} in
        (*'	'*) continue ;;
      esac
      if [ -f "$np_conf_file" ] && [ ! -r "$np_conf_file" ]; then
        printf '!\t%s\tunreadable\n' "${np_conf_file##*/}" >&2
      fi
      [ -f "$np_conf_file" ] && [ -r "$np_conf_file" ] || continue
      printf '%s\n' "${np_conf_file##*/}"
    done | LC_ALL=C sort
  )
  [ -n "$np_conf_names" ] || return 0
  set --
  while IFS= read -r np_conf_name; do
    [ -f "$np_conf_dir/$np_conf_name" ] || continue
    set -- "$@" "$np_conf_dir/$np_conf_name"
  done <<NP_CONF_NAMES
$np_conf_names
NP_CONF_NAMES
  [ "$#" -gt 0 ] || return 0
  LC_ALL=C awk -v kind="$np_conf_kind" -v shown="$np_conf_shown" '
  function trim(s) { gsub(/^[ \t\r\n\v\f]+|[ \t\r\n\v\f]+$/, "", s); return s }
  function isnum(s) {
    return s ~ /^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$/ \
      && s + 0 <= 1.7976931348623157e308 && s + 0 >= -1.7976931348623157e308
  }
  function idok(s,   i, c) {
    if (length(s) >= 192 || s == "") return 0
    if (kind == "plugin") {
      if (substr(s, 1, 10) != "NOTPROTON_" || length(s) == 10) return 0
      return substr(s, 11) ~ /^[A-Z0-9_]+$/
    }
    return length(s) <= 64 && s ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/
  }
  function choiceval(s,   eq) {
    eq = index(s, "=")
    return eq ? trim(substr(s, 1, eq - 1)) : s
  }
  function toolok(s) { sub(/\*$/, "", s); return s ~ /^[A-Za-z0-9._-]+$/ }
  function envok(s,   eq) {
    eq = index(s, "=")
    return eq > 1 && substr(s, 1, eq - 1) ~ /^[A-Z_][A-Z0-9_]*$/
  }
  function relok(s, top) {
    if (substr(s, 1, 1) == "/" || index(s, "..")) return 0
    return top || s ~ /[^.\/]/
  }
  function refuse(scope, c, d) { printf "!\t%s\t%s%s%s\n", scope, c, (d == "" ? "" : ":"), d }
  function schema(   i, f, t, values, mn, mx, st, df) {
    for (i = 1; i <= nreq; i++)
      if (!(req[i] in cnt)) { detail = req[i]; return "missing-required" }
    if (kind == "variant") {
      if (!relok(first["dst"], 1)) { detail = "dst"; return "bad-value" }
      for (i = 1; i <= nkv; i++) {
        if (names[i] == "remove" && !relok(vals[i], 0)) { detail = "remove"; return "bad-value" }
        if (names[i] == "build" && vals[i] !~ /^[A-Za-z0-9.-]+$/) { detail = "build"; return "bad-value" }
      }
      return ""
    }
    for (i = 1; i <= nkv; i++) {
      if (names[i] == "env" && !envok(vals[i])) { detail = "env"; return "bad-value" }
      if (names[i] == "choice" && choiceval(vals[i]) == "") { detail = "choice"; return "bad-value" }
      if (names[i] == "tools" && !toolok(vals[i])) { detail = "tools"; return "bad-value" }
    }
    if (("depends" in cnt) && !idok(first["depends"])) { detail = "depends"; return "bad-value" }
    if (("section" in cnt) && first["section"] != "dev") { detail = "section"; return "bad-value" }
    if (!("type" in cnt)) return ""
    t = first["type"]
    values = ("choice" in cnt) ? cnt["choice"] : 0
    mn = ("min" in cnt); mx = ("max" in cnt); st = ("step" in cnt); df = ("default" in cnt)
    if (t == "choice") {
      if (!values) { detail = "choice"; return "missing-required" }
      return ""
    }
    if (t != "slider") { detail = t; return "bad-type" }
    if ((values && (mn || mx)) || (!values && !(mn && mx)) || values == 1) return "slider-shape"
    if (values) {
      if (df) { for (i = 1; i <= nkv; i++)
                  if (names[i] == "choice" && choiceval(vals[i]) == first["default"]) return ""
                return "bad-default" }
      return ""
    }
    if (!isnum(first["min"])) { detail = "min"; return "bad-value" }
    if (!isnum(first["max"]) || first["max"] + 0 <= first["min"] + 0) { detail = "max"; return "bad-value" }
    if (st && (!isnum(first["step"]) || first["step"] + 0 <= 0)) { detail = "step"; return "bad-value" }
    if (df && (!isnum(first["default"]) || first["default"] + 0 < first["min"] + 0 || first["default"] + 0 > first["max"] + 0))
      return "bad-default"
    return ""
  }
  # Clears a record, refused or not, so nothing it held reaches the next one.
  function reset() {
    id = ""; code = ""; detail = ""; nkv = 0; bytes = 0
    split("", cnt); split("", first)
  }
  function flush(   i, c) {
    if (id == "") { reset(); return }
    c = code
    if (c == "") { detail = ""; c = schema() }
    if (c == "") {
      if (id in seen) { c = "duplicate-id"; detail = "" }
      else if (records >= 32) { c = "limit"; detail = "" }
      else { seen[id] = 1; records++ }
    }
    # conf.c holds 191 bytes of an id and 63 of a field name, and names them that way.
    if (c != "") refuse(substr(id, 1, 191), c, substr(detail, 1, 63))
    else for (i = 1; i <= nkv; i++) printf "%s\t%s\t%s\n", id, names[i], vals[i]
    reset()
  }
  function startfile(   base) {
    base = FILENAME
    sub(/^.*\//, "", base)
    printf "== %s%s%s\n", shown, (shown == "" ? "" : "/"), base
    path = shown (shown == "" ? "" : "/") base
    header = 0; dropped = 0
  }
  BEGIN {
    nkv = 0; records = 0; id = ""; code = ""; detail = ""
    if (kind == "plugin") {
      split("label description description_on section on off depends requires inject env overrides stage tools type choice min max step default suffix", f, " ")
      split("1 1 16 1 1 1 1 4 1 16 1 1 8 1 16 1 1 1 1 1", m, " ")
      split("label", req, " "); nreq = 1
    } else {
      split("label variant src dst build remove", f, " ")
      split("1 1 1 1 8 32", m, " ")
      split("src dst", req, " "); nreq = 2
    }
    for (i in f) most[f[i]] = m[i] + 0
  }
  FNR == 1 { flush(); startfile() }
  dropped { next }
  {
    if (length($0) >= 2048) { reset(); refuse(path, "line-too-long", ""); dropped = 1; next }
    k = $0
    sub(/^[ \t\r\n\v\f]+/, "", k)
    if (k == "" || substr(k, 1, 1) == "#") next
    if (substr(k, 1, 1) == "[") {
      cl = 0
      for (i = length(k); i > 1; i--) if (substr(k, i, 1) == "]") { cl = i; break }
      if (!cl) next
      flush()
      header = 1
      id = trim(substr(k, 2, cl - 2))
      if (id == "") refuse(path, "bad-id", "")
      else if (!idok(id)) { code = "bad-id"; detail = "" }
      next
    }
    eq = index(k, "=")
    if (!eq) next
    if (!header) { reset(); refuse(path, "no-header", ""); dropped = 1; next }
    if (code != "") next
    name = trim(substr(k, 1, eq - 1))
    val = trim(substr(k, eq + 1))
    if (!(name in most)) { code = "unknown-field"; detail = name; next }
    if (val == "") { code = "empty-value"; detail = name; next }
    if (index(val, "\t")) { code = "tab-in-value"; detail = name; next }
    if ((name in cnt ? cnt[name] : 0) >= most[name]) {
      code = (most[name] == 1 ? "duplicate-field" : "limit"); detail = name; next
    }
    if (bytes + length(name) + length(val) + 2 > 4096) { code = "limit"; detail = name; next }
    nkv++; names[nkv] = name; vals[nkv] = val
    bytes += length(name) + length(val) + 2
    if (!(name in cnt)) { cnt[name] = 0; first[name] = val }
    cnt[name]++
  }
  END { flush() }
  ' "$@"
)

# The normalised table is built once per directory and read with these, so nothing below
# parses a descriptor itself.
np_conf_value() {
  printf '%s\n' "$1" | awk -F'\t' -v i="$2" -v f="$3" '$1 == i && $2 == f { print $3; exit }'
}
np_conf_values() {
  printf '%s\n' "$1" | awk -F'\t' -v i="$2" -v f="$3" '$1 == i && $2 == f { print $3 }'
}
np_conf_ids() {
  printf '%s\n' "$1" | awk -F'\t' '$1 != "!" && $1 !~ /^== / && !seen[$1]++ { print $1 }'
}
np_conf_has() {
  printf '%s\n' "$1" | awk -F'\t' -v i="$2" '$1 == i { found = 1 } END { exit !found }'
}
# A path a descriptor names: absolute, or under $HOME however it is written, as
# resolve_home_path in webpatch.c reads it.
np_home_path() {
  # shellcheck disable=SC2088,SC2016
  case "$1" in
    (/*) printf '%s' "$1" ;;
    ("~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;;
    ('$HOME/'*) printf '%s/%s' "$HOME" "${1#'$HOME/'}" ;;
    (*) printf '%s/%s' "$HOME" "$1" ;;
  esac
}
# Every refusal the reader found, logged the way the panel logs its own.
np_conf_log() {
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == "!" {
    printf "=== %s: %s refused, %s ===\n", k, $2, $3
  }' >> "${log:-/dev/null}" 2>&1 || true
}

# A runner variant carries a different build of something that has to be builtin, which is
# the only reason to replace a whole runner rather than drop a DLL in the prefix. Each one
# is a descriptor naming a tree and where that tree lands in the runner, so nothing here
# knows what any particular variant contains. Variants are clones, so resolving per game
# means two games can use different ones at once.
np_variant_conf_dir="$np_support/variants"
np_variant_used=""
np_conf_var_table=$(np_conf_normalise "$np_variant_conf_dir" "" variant) || np_conf_var_table=""
np_conf_log "$np_conf_var_table" variants
np_variant_say() {
  echo "=== variants: $* ===" >> "${log:-/dev/null}" 2>&1 || true
}

# Mirrors np_compat_tool_builds in compat.c: the panel and the launch path have to agree
# on which architecture a tool runs, or one offers a variant the other refuses.
np_variant_arch() {
  case "$np_flavor" in
    (fex) printf 'aarch64' ;;
    (*)   printf 'x86_64' ;;
  esac
}

# ./lib/ and lib are the same place, as var_norm in webpatch.c reads them.
np_variant_norm() {
  printf '%s\n' "$1" | awk -F/ '{
    o = ""
    for (i = 1; i <= NF; i++) if ($i != "" && $i != ".") o = (o == "" ? $i : o "/" $i)
    printf "%s", o
  }'
}

# Whether a tree has anything this runner can use, read from the top of the tree the way
# var_fits in webpatch.c reads it: files there land in dst, and each folder lands where dst
# has one of the same name. A folder named for an architecture only counts for the runner
# that runs it, and a tree naming any architecture has to land one this runner runs, or
# arm64 Wine would be handed x86_64 files and never read them.
np_variant_fits() {
  np_v_lands=0
  np_v_named=0
  np_v_fits=0
  np_v_want_arch=$(np_variant_arch)
  np_v_into="$np_support/runners/crossover-$np_build/CrossOver/$2"
  for np_v_e in "$1"/*; do
    # The overlay copies regular files only, so a link never lands.
    [ ! -L "$np_v_e" ] || continue
    if [ -f "$np_v_e" ]; then
      [ ! -d "$np_v_into" ] || np_v_lands=1
      continue
    fi
    [ -d "$np_v_e" ] || continue
    [ -n "$(find "$np_v_e" -name '.?*' -prune -o -type f -print -quit 2>/dev/null)" ] || continue
    np_v_here=0
    if [ -d "$np_v_into/${np_v_e##*/}" ]; then
      np_v_here=1
      np_v_lands=1
    fi
    np_v_d_arch=$(np_variant_dir_arch "${np_v_e##*/}")
    [ -n "$np_v_d_arch" ] || continue
    np_v_named=1
    if [ "$np_v_here" = 1 ] && [ "$np_v_d_arch" = "$np_v_want_arch" ]; then
      np_v_fits=1
    fi
  done
  # A remove lands when the runner has what it names.
  while IFS= read -r np_v_r; do
    [ -n "$np_v_r" ] || continue
    if [ -e "$np_v_into/$np_v_r" ] || [ -L "$np_v_into/$np_v_r" ]; then
      np_v_lands=1
    fi
  done <<NP_V_REMOVES
$np_v_removes
NP_V_REMOVES
  [ "$np_v_lands" = 1 ] && { [ "$np_v_named" = 0 ] || [ "$np_v_fits" = 1 ]; }
}

# Overwriting a file Wine ships ties a variant to its build. New files and DXMT or D3DMetal folders don't.
np_variant_wine_hit() {
  np_v_wbase="$np_support/runners/crossover-$np_build/CrossOver"
  ( cd "$1" && find . -name '.?*' -prune -o -type f -print ) |
    awk -v d="$(np_variant_norm "$2")" '{
      sub(/^\.\//, ""); p = (d == "" ? $0 : d "/" $0)
      if (tolower(p) ~ /^(bin|share\/wine|lib\/wine|lib64\/wine)\//) print p
    }' |
    while IFS= read -r np_v_w; do
      if [ -f "$np_v_wbase/$np_v_w" ]; then
        printf '%s' "$np_v_w"
        break
      fi
    done
}

# The architecture a directory in a tree is for, empty when it names none. A runner can
# hold more than one slot, so landing somewhere is not the same as being usable.
np_variant_dir_arch() {
  case "$1" in
    (x86_64|x86_64-*)   printf 'x86_64' ;;
    (aarch64|aarch64-*) printf 'aarch64' ;;
    (i386|i386-*)       printf 'i386' ;;
    (arm64ec|arm64ec-*) printf 'arm64ec' ;;
  esac
}

# ntdll.dll carries the Steam bridge patch and ntdll.so has to match it, so variants keep off both and off lsteamclient.
np_variant_bridge_hit() {
  # APFS ignores case, so NTDLL.DLL is ntdll.dll.
  np_v_nd=$(np_variant_norm "$2" | tr '[:upper:]' '[:lower:]')
  np_v_nr=""
  while IFS= read -r np_v_x; do
    [ -n "$np_v_x" ] || continue
    np_v_nr="$np_v_nr$(np_variant_norm "$np_v_nd/$np_v_x" | tr '[:upper:]' '[:lower:]')
"
  done <<NP_V_REMOVES
$3
NP_V_REMOVES
  for np_v_slot in x86_64 i386 aarch64 arm64ec; do
    for np_v_p in "lib/wine/$np_v_slot-windows/ntdll.dll" "lib/wine/$np_v_slot-windows/lsteamclient.dll" \
                  "lib/wine/$np_v_slot-unix/ntdll.so" "lib/wine/$np_v_slot-unix/lsteamclient.so"; do
      case "
$np_v_nr" in
        (*"
$np_v_p
"*) printf '%s' "$np_v_p"; return 0 ;;
      esac
    done
  done
  # A tree on a case-sensitive volume can't be probed by name, so every file gets read.
  np_v_p=$( ( cd "$1" && find . -name '.?*' -prune -o -type f -print ) |
    awk -v d="$np_v_nd" '{
      sub(/^\.\//, ""); p = tolower(d == "" ? $0 : d "/" $0)
      if (p ~ /^lib\/wine\/(x86_64|i386|aarch64|arm64ec)-(windows\/(ntdll|lsteamclient)\.dll|unix\/(ntdll|lsteamclient)\.so)$/) { print p; exit }
    }')
  [ -n "$np_v_p" ] || return 1
  printf '%s' "$np_v_p"
}

# Requested names, split on +, sorted so a combination is named and overlaid the same way
# whichever order it was asked for in.
np_variant_names() {
  printf '%s' "$1" | tr '+' '\n' | grep -v '^$' | LC_ALL=C sort -u | tr '\n' ' '
}
# "+" joins them because no build id or variant id can hold one, so no two requests and
# no base runner share a directory.
np_variant_dir_name() {
  np_v_joined="crossover-$np_build"
  for np_v_n in $1; do
    np_v_joined="$np_v_joined+$np_v_n"
  done
  printf '%s' "$np_v_joined"
}

# Reads one descriptor into np_v_src and np_v_dst. Unknown keys are refused so a typo
# cannot quietly mean something else, and a descriptor that cannot be used drops the
# variant rather than stopping the game.
np_variant_read() {
  np_v_src=$(np_conf_value "$np_conf_var_table" "$1" src)
  np_v_dst=$(np_conf_value "$np_conf_var_table" "$1" dst)
  np_v_removes=$(np_conf_values "$np_conf_var_table" "$1" remove)
  np_v_builds=$(np_conf_values "$np_conf_var_table" "$1" build)
  if [ -z "$np_v_src" ] || [ -z "$np_v_dst" ]; then
    np_variant_say "$1 has no usable descriptor"
    return 1
  fi
  if [ -n "$np_v_builds" ] && ! printf '%s\n' "$np_v_builds" | grep -qxF "$np_build"; then
    np_variant_say "$1 is for $(printf '%s' "$np_v_builds" | tr '\n' ' ') and this runner is $np_build, so it is left out"
    return 1
  fi
  np_v_src=$(np_home_path "$np_v_src")
  if [ ! -d "$np_v_src" ]; then
    np_variant_say "$1 builds from $np_v_src, which is not there"
    return 1
  fi
  if ! np_variant_fits "$np_v_src" "$np_v_dst"; then
    np_variant_say "$1 has nothing for $np_v_want_arch that lands in this runner, so it is refused"
    return 1
  fi
  if np_v_hit=$(np_variant_bridge_hit "$np_v_src" "$np_v_dst" "$np_v_removes"); then
    np_variant_say "$1 would change $np_v_hit, which carries NotProton's Steam bridge, so it is refused"
    return 1
  fi
  if [ -z "$np_v_builds" ] && np_v_hit=$(np_variant_wine_hit "$np_v_src" "$np_v_dst") \
     && [ -n "$np_v_hit" ]; then
    np_variant_say "$1 replaces $np_v_hit, which is Wine's own, so it has to name the build it was made for: build = $np_build"
    return 1
  fi
  return 0
}

# What the variant should be made of. Rebuilding is decided by comparing this against the
# copy recorded in the built runner, which is a handful of stat calls. The base runner's
# patched files are in it too, or re-patching the runner would leave variants on the old ntdll.
np_variant_manifest() {
  for np_v_name in $1; do
    np_variant_read "$np_v_name" || return 1
    printf '%s %s\n' "$np_v_name" "$np_v_dst"
    ( cd "$np_v_src" && find . -name '.?*' -prune -o -type f -exec stat -f '%N %z %m' {} + ) | LC_ALL=C sort
    printf '%s\n' "$np_v_removes" | awk 'NF { print "remove " $0 }'
  done
  np_v_mbase="$np_support/runners/crossover-$np_build/CrossOver"
  for np_v_bf in "$np_v_mbase/share/wine/wine.inf" \
    "$np_v_mbase"/lib/wine/*-windows/ntdll.dll \
    "$np_v_mbase"/lib/wine/*-windows/lsteamclient.dll \
    "$np_v_mbase"/lib/wine/*-unix/lsteamclient.so; do
    [ -f "$np_v_bf" ] || continue
    stat -f 'base %N %d %i %z %m' "$np_v_bf" 2>/dev/null || true
  done
  return 0
}

# Sizes and times are left out, so rebuilding the same files doesn't rerun wine.inf in every prefix.
np_variant_layout_of() {
  awk '$1 == "base" { next } /^\.\// { sub(/ [0-9]+ [0-9]+$/, "") } { print }' | /sbin/md5 -q
}

# Wine keeps a wineserver running inside the runner, so a process running from there is a
# live session and the tree under it must not move.
np_variant_busy() {
  # shellcheck disable=SC2009 # pgrep matches arguments; the executable path is the signal
  np_v_ps=$(ps -axww -o comm= 2>/dev/null) || return 0
  printf '%s\n' "$np_v_ps" | grep -qF "$1/"
}

# winebuild --builtin writes this over the DOS stub, and it is the whole reason a tree can
# be shared as a zip: the mark travels in the file, so nobody downstream needs a toolchain.
np_variant_builtin() {
  [ "$(dd if="$1" bs=1 skip=64 count=16 2>/dev/null)" = "Wine builtin DLL" ]
}

np_variant_macho() {
  case "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" in
    (cffaedfe | cefaedfe | feedfacf | feedface | cafebabe | bebafeca) return 0 ;;
  esac
  return 1
}

# arm64 won't load an edited Mach-O, and a replaced loader or wineserver needs the old file's entitlements back.
np_variant_sign() {
  if [ -n "$2" ]; then
    printf '%s' "$2" > "$np_v_root/.np-entitlements.plist" || return 1
    /usr/bin/codesign -f -s - --options runtime \
      --entitlements "$np_v_root/.np-entitlements.plist" "$1" >> "${log:-/dev/null}" 2>&1 || return 1
    rm -f "$np_v_root/.np-entitlements.plist"
    return 0
  fi
  /usr/bin/codesign -v "$1" 2>/dev/null && return 0
  /usr/bin/codesign -f -s - "$1" >> "${log:-/dev/null}" 2>&1
}

# A tree can hold more architectures than a runner has slots for -- DXMT builds one arch
# per build directory but installs them into one prefix, so a shared tree may carry both.
# A directory the runner does not have is skipped rather than fatal, and a variant that
# lands nothing is refused, which is what catches a tree meant for the other machine.
np_variant_overlay() {
  np_v_root="$1"
  : > "$np_v_root/.np-laid" || return 1
  for np_v_name in $2; do
    np_variant_read "$np_v_name" || return 1
    np_v_nd=$(np_variant_norm "$np_v_dst")
    ( cd "$np_v_src" && find . -name '.?*' -prune -o -type f -print ) > "$np_v_root/.np-files" || return 1

    # Two variants touching one file is allowed (the later wins) but rarely meant.
    {
      awk -v d="$np_v_nd" '{ sub(/^\.\//, ""); print (d == "" ? $0 : d "/" $0) }' "$np_v_root/.np-files"
      while IFS= read -r np_v_x; do
        [ -z "$np_v_x" ] || { np_variant_norm "$np_v_nd/$np_v_x"; echo; }
      done <<NP_V_REMOVES
$np_v_removes
NP_V_REMOVES
    } > "$np_v_root/.np-mine"
    np_v_clash=$(awk 'FILENAME == ARGV[1] { a[$0]; next } ($0 in a)' \
      "$np_v_root/.np-laid" "$np_v_root/.np-mine" | head -3 | tr '\n' ' ')
    [ -z "$np_v_clash" ] ||
      np_variant_say "$np_v_name changes ${np_v_clash% } after an earlier variant did, and $np_v_name's copy is the one that runs"
    cat "$np_v_root/.np-mine" >> "$np_v_root/.np-laid"

    while IFS= read -r np_v_x; do
      [ -n "$np_v_x" ] || continue
      np_v_at="$np_v_root/CrossOver/$np_v_dst/$np_v_x"
      if [ -L "$np_v_at" ] || [ -f "$np_v_at" ]; then
        rm -f "$np_v_at" || return 1
      elif [ -e "$np_v_at" ]; then
        np_variant_say "$np_v_name: $np_v_x is a folder, and only files are removed, so it stays"
      else
        np_variant_say "$np_v_name: $np_v_x is not in this runner, so there is nothing to remove"
      fi
    done <<NP_V_REMOVES
$np_v_removes
NP_V_REMOVES

    # Forks are what a Wine-sized tree costs, so the unlinks and quarantine strips go in batches.
    : > "$np_v_root/.np-at"
    : > "$np_v_root/.np-take"
    np_v_skipped=""
    while IFS= read -r np_v_rel; do
      np_v_rel=${np_v_rel#./}
      np_v_at="$np_v_root/CrossOver/$np_v_dst/$np_v_rel"
      if [ ! -d "${np_v_at%/*}" ]; then
        case "$np_v_rel" in */*) np_v_dir=${np_v_rel%/*} ;; *) np_v_dir=. ;; esac
        case " $np_v_skipped " in
          *" $np_v_dir "*) ;;
          *) np_v_skipped="$np_v_skipped $np_v_dir" ;;
        esac
        continue
      fi
      printf '%s\n' "$np_v_rel" >> "$np_v_root/.np-take"
      printf '%s\0' "$np_v_at" >> "$np_v_root/.np-at"
    done < "$np_v_root/.np-files"
    xargs -0 rm -f < "$np_v_root/.np-at" || return 1

    np_v_laid=0
    while IFS= read -r np_v_rel; do
      np_v_at="$np_v_root/CrossOver/$np_v_dst/$np_v_rel"
      # A DLL is never Mach-O, and everything else gets opened to check.
      np_v_ent=""
      np_v_lc=$(printf '%s' "${np_v_rel##*/}" | tr '[:upper:]' '[:lower:]')
      np_v_signable=1
      case "$np_v_lc" in (*.dll) np_v_signable=0 ;; esac
      np_v_was="$np_support/runners/crossover-$np_build/CrossOver/$np_v_dst/$np_v_rel"
      if [ "$np_v_signable" = 1 ] && [ -f "$np_v_was" ] && np_variant_macho "$np_v_was"; then
        np_v_ent=$(/usr/bin/codesign -d --entitlements - --xml "$np_v_was" 2>/dev/null) || np_v_ent=""
        case "$np_v_ent" in
          # Ad-hoc signing can't carry Apple-granted entitlements like the FEX loader's cross-architecture-support.
          (*'<key>com.apple.developer.'*)
            np_variant_say "$np_v_name/$np_v_rel would replace a file holding an entitlement only Apple can sign for, so $np_v_name is refused"
            return 1 ;;
          (*'<key>'*) ;;
          (*) np_v_ent="" ;;
        esac
      fi
      cp -c "$np_v_src/$np_v_rel" "$np_v_at" 2>/dev/null \
        || cp "$np_v_src/$np_v_rel" "$np_v_at" || return 1
      case "$np_v_lc" in
        *.dll)
          if ! np_variant_builtin "$np_v_at"; then
            np_variant_say "$np_v_name/$np_v_rel is not marked as a Wine builtin, so it would load as native and fail; $np_v_name is refused"
            return 1
          fi ;;
      esac
      if [ "$np_v_signable" = 1 ] && np_variant_macho "$np_v_at" \
         && ! np_variant_sign "$np_v_at" "$np_v_ent"; then
        np_variant_say "$np_v_name/$np_v_rel could not be signed and macOS would not load it, so $np_v_name is refused"
        return 1
      fi
      np_v_laid=$(( np_v_laid + 1 ))
    done < "$np_v_root/.np-take"
    # A downloaded tree arrives quarantined and Gatekeeper can refuse to dlopen it.
    xargs -0 xattr -d com.apple.quarantine < "$np_v_root/.np-at" 2>/dev/null || true
    rm -f "$np_v_root/.np-files" "$np_v_root/.np-mine" "$np_v_root/.np-take" "$np_v_root/.np-at"
    [ -z "$np_v_skipped" ] ||
      np_variant_say "$np_v_name:$np_v_skipped has no counterpart in this runner, skipped"
    if [ "$np_v_laid" -eq 0 ] && [ -z "$np_v_removes" ]; then
      np_variant_say "nothing in $np_v_name belongs in this runner, so it is refused"
      return 1
    fi
  done
  rm -f "$np_v_root/.np-laid"
  return 0
}

# Found before the clone, or a variant that can never build costs a whole runner copy every launch.
np_variant_apple_hit() {
  np_v_abase="$np_support/runners/crossover-$np_build/CrossOver"
  for np_v_name in $1; do
    np_variant_read "$np_v_name" || continue
    np_v_ah=$( ( cd "$np_v_src" && find . -name '.?*' -prune -o -type f -print ) |
      while IFS= read -r np_v_rel; do
        np_v_rel=${np_v_rel#./}
        np_v_was="$np_v_abase/$np_v_dst/$np_v_rel"
        [ -f "$np_v_was" ] || continue
        np_variant_macho "$np_v_was" || continue
        case "$(/usr/bin/codesign -d --entitlements - --xml "$np_v_was" 2>/dev/null || true)" in
          (*'<key>com.apple.developer.'*) printf '%s/%s' "$np_v_name" "$np_v_rel"; break ;;
        esac
      done)
    [ -z "$np_v_ah" ] || { printf '%s' "$np_v_ah"; return 0; }
  done
}

# Builds into a scratch directory and moves it in, so a failure leaves the previous build
# standing and the game runs last-known-good rather than a half-written tree.
# The lock is lockf's, held by a subshell, so it goes when the launch does however it ends
# and nothing ever has to decide that a lock was left behind.
np_variant_build() (
  np_v_target="$1"
  np_v_names="$2"
  np_v_want="$3"
  np_v_stem="$4"
  np_v_base="$np_support/runners/crossover-$np_build"
  # Hidden, as the app's own scratch is, so nothing that lists runners takes these for one.
  np_v_scratch="${np_v_target%/*}/.${np_v_target##*/}"
  np_v_lock="${np_v_stem%/*}/.${np_v_stem##*/}.lock"
  np_v_new="$np_v_scratch.new"
  np_v_old="$np_v_scratch.old"

  if [ ! -d "$np_v_base/CrossOver/lib/wine" ]; then
    np_variant_say "no base runner at $np_v_base yet, so nothing can be built from it"
    exit 1
  fi
  [ ! -L "$np_v_lock" ] || exit 1
  exec 7>> "$np_v_lock" || exit 1
  if ! /usr/bin/lockf -s -t 120 7; then
    np_variant_say "another launch is still building ${np_v_stem##*/}"
    exit 1
  fi
  trap 'rm -rf "$np_v_new"; exit 143' TERM
  trap 'rm -rf "$np_v_new"; exit 130' INT
  trap 'rm -rf "$np_v_new"; exit 129' HUP

  # Another launch may have built it, or started a game from it, while this one waited.
  if [ -d "$np_v_target/CrossOver/lib/wine" ]; then
    if [ "$(cat "$np_v_target/CrossOver/.notproton-variant" 2>/dev/null || true)" = "$np_v_want" ] \
       && [ "${NOTPROTON_VARIANT_REBUILD:-}" != 1 ]; then
      exit 0
    fi
    if np_variant_busy "$np_v_target"; then
      np_variant_say "a game is running from ${np_v_target##*/}, leaving it as it is"
      exit 0
    fi
  fi

  rm -rf "$np_v_new" "$np_v_old"
  np_v_hit=$(np_variant_apple_hit "$np_v_names")
  if [ -n "$np_v_hit" ]; then
    np_variant_say "$np_v_hit would replace a file holding an entitlement only Apple can sign for, so it is refused"
    exit 1
  fi
  np_variant_say "building ${np_v_target##*/} from $np_v_names"
  if ! { cp -c -R "$np_v_base" "$np_v_new" 2>/dev/null || cp -R "$np_v_base" "$np_v_new"; } \
     || ! np_variant_overlay "$np_v_new" "$np_v_names" \
     || ! printf '%s\n' "$np_v_want" > "$np_v_new/CrossOver/.notproton-variant" \
     || ! : > "$np_v_new/.notproton-used"; then
    rm -rf "$np_v_new"
    np_variant_say "could not build ${np_v_target##*/}"
    exit 1
  fi
  if [ -d "$np_v_target" ] && ! mv "$np_v_target" "$np_v_old"; then
    rm -rf "$np_v_new"
    np_variant_say "could not move the old ${np_v_target##*/} aside"
    exit 1
  fi
  if ! mv "$np_v_new" "$np_v_target"; then
    [ ! -d "$np_v_old" ] || mv "$np_v_old" "$np_v_target" || true
    rm -rf "$np_v_new"
    np_variant_say "could not move the new ${np_v_target##*/} in"
    exit 1
  fi
  rm -rf "$np_v_old"
  np_variant_say "built ${np_v_target##*/}"
)

# Newest build that worked, skipping any made before a re-patch since those carry the old Steam bridge.
np_variant_last_good() {
  np_v_base_now=$(printf '%s\n' "$2" | grep '^base ' || true)
  # shellcheck disable=SC2012 # the names are ours, and ls is what sorts by time
  ls -dt "$1"@*/.notproton-used 2>/dev/null | while IFS= read -r np_v_lg; do
    np_v_lg=${np_v_lg%/.notproton-used}
    [ -d "$np_v_lg/CrossOver/lib/wine" ] || continue
    [ "$(grep '^base ' "$np_v_lg/CrossOver/.notproton-variant" 2>/dev/null || true)" = "$np_v_base_now" ] || continue
    : > "$np_v_lg/.notproton-used" 2>/dev/null || continue
    printf '%s' "$np_v_lg"
    break
  done
}

# Ten minutes covers a launch that resolved an old build but hasn't started Wine from it yet.
np_variant_gc() {
  np_variant_sweep "$1"
  for np_v_old in "$1"@*; do
    [ -d "$np_v_old" ] && [ "$np_v_old" != "$2" ] || continue
    [ -z "$(find "$np_v_old/.notproton-used" -mmin -10 2>/dev/null)" ] || continue
    np_variant_busy "$np_v_old" && continue
    # Renamed first, so a kill partway can't leave half a runner under a name that gets reused.
    np_v_trash="${np_v_old%/*}/.${np_v_old##*/}.removing"
    mv "$np_v_old" "$np_v_trash" 2>/dev/null || continue
    rm -rf "$np_v_trash" && np_variant_say "removed ${np_v_old##*/}, which nothing uses any more"
  done
}

# What a killed build or cleanup left behind. Only touched with the build lock held, or it could be a live build's.
np_variant_sweep() (
  np_v_sw="${1%/*}/.${1##*/}"
  for np_v_s in "$np_v_sw"@*.new "$np_v_sw"@*.old "$np_v_sw"@*.removing; do
    [ -e "$np_v_s" ] || continue
    [ ! -L "$np_v_sw.lock" ] || exit 0
    exec 7>> "$np_v_sw.lock" || exit 0
    /usr/bin/lockf -s -t 0 7 || exit 0
    rm -rf "$np_v_sw"@*.new "$np_v_sw"@*.old "$np_v_sw"@*.removing
    exit 0
  done
)

# One name in a request that has lost its descriptor must not take the rest with it: the
# panel keeps a launch option a game already carries, and a game outlives a descriptor.
np_variant_usable() {
  np_v_keep=""
  np_v_drop=""
  for np_v_name in $1; do
    if np_variant_read "$np_v_name"; then
      np_v_keep="$np_v_keep$np_v_name "
    else
      np_v_drop="$np_v_drop$np_v_name "
    fi
  done
}

# Sets np_variant_root to a runner carrying the requested variants, building it when the
# trees behind it have moved on. Returns 1 to leave the game on the base runner, so a
# stale launch option never stops it starting.
np_variant_resolve() {
  np_v_asked=$(np_variant_names "$1")
  [ -n "$np_v_asked" ] || return 1
  np_variant_usable "$np_v_asked"
  [ -z "$np_v_drop" ] || np_variant_say "ignoring ${np_v_drop% }, which cannot be used"
  [ -n "$np_v_keep" ] || return 1

  np_v_sel=${np_v_keep% }
  np_variant_used="$np_v_sel"
  np_v_want=$(np_variant_manifest "$np_v_sel") || np_v_want=""
  [ -n "$np_v_want" ] || return 1
  np_v_stem="$np_support/runners/$(np_variant_dir_name "$np_v_sel")"
  np_variant_key=${np_v_stem##*/crossover-"$np_build"}
  # Named for its contents, so a rebuild never moves a runner out from under a running game.
  np_variant_root="$np_v_stem@$(printf '%s\n' "$np_v_want" | /sbin/md5 -q | cut -c1-12)"
  np_variant_layout=$(printf '%s\n' "$np_v_want" | np_variant_layout_of)

  if [ ! -d "$np_variant_root/CrossOver/lib/wine" ] || [ "${NOTPROTON_VARIANT_REBUILD:-}" = 1 ] \
     || [ "$(cat "$np_variant_root/CrossOver/.notproton-variant" 2>/dev/null || true)" != "$np_v_want" ]; then
    if ! np_variant_build "$np_variant_root" "$np_v_sel" "$np_v_want" "$np_v_stem" \
       && [ ! -d "$np_variant_root/CrossOver/lib/wine" ]; then
      np_variant_root=$(np_variant_last_good "$np_v_stem" "$np_v_want")
      [ -n "$np_variant_root" ] || return 1
      np_variant_say "running ${np_variant_root##*/}, the last build of it that worked"
      np_variant_layout=$(np_variant_layout_of < "$np_variant_root/CrossOver/.notproton-variant")
    fi
  fi
  : > "$np_variant_root/.notproton-used" 2>/dev/null || true
  np_variant_gc "$np_v_stem" "$np_variant_root"
  np_variant_root="$np_variant_root/CrossOver"
  return 0
}

# A variant can bring a module name the base runner never had. Prefixes are copied from a
# template built before the variant existed, so that name has no entry in system32 and the
# loader will not reach the runner's copy: a forward into it fails with "module not found"
# and the first real call aborts the game. Putting the file in the prefix registers the
# name. A name the prefix already has resolves on its own and is left as it is, which is
# every DLL a variant merely replaces.
np_variant_stage_prefix() {
  [ -n "$np_variant_used" ] || return 0
  np_v_want=$(np_variant_arch)
  for np_v_name in $np_variant_used; do
    np_variant_read "$np_v_name" || continue
    for np_v_from in "$np_v_src"/*-windows/*.dll; do
      [ -f "$np_v_from" ] || continue
      np_v_rel=${np_v_from#"$np_v_src"/}
      # The runner holds every architecture, the prefix only takes the one this tool runs.
      np_v_d_arch=$(np_variant_dir_arch "${np_v_rel%%/*}")
      case "$np_v_d_arch" in
        (i386) ;;
        (arm64ec) [ "$np_v_want" = aarch64 ] || continue ;;
        (*) [ "$np_v_d_arch" = "$np_v_want" ] || continue ;;
      esac
      case "$np_v_rel" in
        (i386-windows/*) np_v_into="$WINEPREFIX/drive_c/windows/syswow64" ;;
        (*) np_v_into="$WINEPREFIX/drive_c/windows/system32" ;;
      esac
      # Copy what the runner ended up with, not the tree it was built from, and skip an
      # architecture this runner has no slot for -- the same rule the overlay applies.
      np_v_live="$CX_ROOT/$np_v_dst/$np_v_rel"
      [ -f "$np_v_live" ] && [ -d "$np_v_into" ] || continue
      np_v_reg="$np_v_into/${np_v_rel##*/}"
      np_v_mark="${np_v_into##*/}/${np_v_rel##*/}"
      # Only a file registered here is ours to refresh after a rebuild.
      if [ -e "$np_v_reg" ]; then
        grep -qxF "$np_v_mark" "$WINEPREFIX/.notproton-variant-modules" 2>/dev/null || continue
        ! cmp -s "$np_v_live" "$np_v_reg" || continue
      fi
      if cp -f "$np_v_live" "$np_v_reg.np-stage.$$" && mv -f "$np_v_reg.np-stage.$$" "$np_v_reg"; then
        grep -qxF "$np_v_mark" "$WINEPREFIX/.notproton-variant-modules" 2>/dev/null ||
          echo "$np_v_mark" >> "$WINEPREFIX/.notproton-variant-modules" || true
        np_variant_say "$np_v_name: registered ${np_v_rel##*/} in ${np_v_into##*/}"
      else
        rm -f "$np_v_reg.np-stage.$$"
        np_variant_say "$np_v_name: could not register ${np_v_rel##*/} in ${np_v_into##*/}"
      fi
    done
  done
}

CX_ROOT="$np_support/runners/crossover-$np_build/CrossOver"
np_variant=${NOTPROTON_RUNNER_VARIANT:-}
np_variant_key=""
np_variant_layout=""
case "$np_variant" in *[!A-Za-z0-9._+-]*) np_variant="" ;; esac
if [ -n "$np_variant" ]; then
  if np_variant_resolve "$np_variant"; then
    CX_ROOT="$np_variant_root"
  else
    np_variant=""
    np_variant_key=""
    np_variant_layout=""
    np_variant_used=""
  fi
fi
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
      CX_GRAPHICS_BACKEND=d3dmetal | D3DM_ENABLE_METALFX=[01] | D3DM_SUPPORT_DXR=[01] | D3DM_MTL4=[01] | D3DM_MAX_FPS=[0-9]* | ROSETTA_ADVERTISE_AVX=[01])
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
    [ ! -e "${inf%/share/wine/wine.inf}/.notproton-variant" ] || continue
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

# Wine reruns wine.inf only when its mtime changes, which swapping a variant's files doesn't do.
note_variant_switch() {
  record="$STEAM_COMPAT_DATA_PATH/notproton-variant"
  had=$(cat "$record" 2>/dev/null || true)
  if [ "$had" != "$np_variant_layout" ] && [ -f "$WINEPREFIX/system.reg" ]; then
    printf '0\n' > "$WINEPREFIX/.update-timestamp" 2>/dev/null || true
    echo "=== runner variant files changed (${had:-none} to ${np_variant_layout:-none}), wine.inf reruns ===" >> "$log" 2>&1 || true
  fi
  if [ -n "$np_variant_layout" ]; then
    printf '%s\n' "$np_variant_layout" > "$record" 2>/dev/null || true
  else
    rm -f "$record"
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
  [ ! -f "$WINEPREFIX/system.reg" ] || in_registry=$(LC_ALL=C awk '
    /^\[/ {
      line = tolower($0)
      prefix = "[system\\\\controlset001\\\\services\\\\winebus\\\\devices\\\\"
      if (index(line, prefix) != 1) next
      id = substr(line, length(prefix) + 1, 9)
      if (id ~ /^[0-9a-f]{4}\/[0-9a-f]{4}$/ && substr(line, length(prefix) + 10, 1) == "]") print id
    }' "$WINEPREFIX/system.reg" \
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
  [ ! -f "$WINEPREFIX/system.reg" ] || hidraw_set=$(LC_ALL=C awk '
      /^\[/ { s = index(tolower($0), "[system\\\\controlset001\\\\services\\\\winebus]") == 1; next }
      s && tolower($0) == "\"disablehidraw\"=dword:00000001" { print 1; exit }' "$WINEPREFIX/system.reg")
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
  dpi_registry=/dev/null
  [ ! -f "$WINEPREFIX/user.reg" ] || dpi_registry="$WINEPREFIX/user.reg"
  read -r retina_was dpi <<EOF
$(LC_ALL=C awk '
  /^\[/ { s = 0
    line = tolower($0)
    if (index(line, "[software\\\\wine\\\\mac driver]") == 1) s = 1
    else if (index(line, "[control panel\\\\desktop]") == 1) s = 2
    next }
  s { $0 = tolower($0) }
  s == 1 && $0 ~ /^"retinamode"="[yt1]/ { r = 1 }
  s == 2 && $0 ~ /^"logpixels"=dword:[0-9a-f]+$/ && length($0) <= 26 { d = substr($0, 19) }
  END { print r + 0, d }' "$dpi_registry")
EOF
  [ -n "$dpi" ] || [ ! -f "$WINEPREFIX/system.reg" ] || dpi=$(LC_ALL=C awk '
      /^\[/ { s = index(tolower($0), "[system\\\\controlset001\\\\hardware profiles\\\\current\\\\software\\\\fonts]") == 1; next }
      s { $0 = tolower($0) }
      s && $0 ~ /^"logpixels"=dword:[0-9a-f]+$/ && length($0) <= 26 { print substr($0, 19); exit }' "$WINEPREFIX/system.reg")
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

prefix_up_to_date() {
  [ -r "$WINEPREFIX/.update-timestamp" ] || return 1
  read -r stamp _ < "$WINEPREFIX/.update-timestamp" || return 1
  stamp=${stamp%"$(printf '\r')"}
  case "$stamp" in '' | *[!0-9]*) return 1 ;; esac
  [ "$stamp" = "$(stat -f %m "$CX_ROOT/share/wine/wine.inf" 2>/dev/null)" ]
}

# Proton only writes the registry when its prefix version changes.
settings_already_applied() {
  prefix_up_to_date || return 1
  [ -f "$WINEPREFIX/system.reg" ] && [ -f "$WINEPREFIX/user.reg" ] || return 1
  LC_ALL=C awk '
    function double(s,   out, i) {
      out = ""
      while ((i = index(s, "\\")) > 0) { out = out substr(s, 1, i) "\\"; s = substr(s, i + 1) }
      return out s
    }
    FNR == 1 {
      file++
      root = file == 2 ? "hkey_local_machine\\" : "hkey_current_user\\"
      key = ""
    }
    { sub(/\r$/, "") }
    /^\[/ {
      key = ""
      end = index($0, "]")
      if (!end) { if (file == 1) bad = 1; next }
      name = tolower(substr($0, 2, end - 2))
      if (file == 1) {
        deleted = sub(/^-/, "", name)
        ccs = "hkey_local_machine\\system\\currentcontrolset\\"
        if (index(name, ccs) == 1)
          name = "hkey_local_machine\\system\\controlset001\\" substr(name, length(ccs) + 1)
        split(name, part, "\\")
        name = substr(name, 1, length(part[1]) + 1) double(substr(name, length(part[1]) + 2))
        if (deleted) gone[name] = 1
        else { key = name; wanted[name] = 1 }
        next
      }
      name = root name
      for (g in gone) if (name == g || index(name, g "\\\\") == 1) bad = 1
      if (name in wanted) key = name
      next
    }
    key == "" || !match($0, /^("([^"\\]|\\.)*"|@)=/) { next }
    {
      name = tolower(substr($0, 1, RLENGTH - 1))
      value = substr($0, RLENGTH + 1)
      if (file == 1) want[key, name] = value
      else have[key, name] = value
    }
    END {
      if (file != 3) exit 1
      for (kv in want) {
        if (want[kv] == "-") { if (kv in have) bad = 1 }
        else if (!(kv in have) || have[kv] != want[kv]) bad = 1
      }
      exit bad
    }
  ' "$settings_file" "$WINEPREFIX/system.reg" "$WINEPREFIX/user.reg"
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
  if settings_already_applied; then
    import_status=0
    echo "=== prefix settings already applied, skipped the import ===" >> "$log" 2>&1 || true
  else
    without_lock_fds "$WINELOADER" reg import "C:\\${settings_file##*/}" >> "$log" 2>&1 \
      && import_status=0 || import_status=$?
  fi
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
if [ -n "${NOTPROTON_RUNNER_VARIANT:-}" ]; then
  if [ -n "$np_variant_used" ]; then
    echo "runner: variant asked for $NOTPROTON_RUNNER_VARIANT, using $np_variant_used" \
      >> "$log" 2>&1 || true
  else
    echo "=== runner variant ${NOTPROTON_RUNNER_VARIANT} not installed, using the base runner ===" \
      >> "$log" 2>&1 || true
  fi
fi

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
  # Variants get their own template slot or they'd keep evicting the stock runner's.
  template_dir="$template_cache/$runner_id$np_variant_key"
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
      name=${src##*/}
      case "$app_id:$name" in
        1313860:arial.ttf|1506830:arial.ttf) src="$dir/alt/$name" ;;
      esac
      dst="$fonts_dir/$name"
      if [ -L "$dst" ] && [ "$dst" -ef "$src" ]; then
        :
      elif [ -L "$dst" ]; then
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
  note_variant_switch
  stage_step="prefix switch check"
  offer_switch_rebuild
  echo "sync: WINEMSYNC=$WINEMSYNC from $msync_from" >> "$log" 2>&1 || true
  if [ "${wine_unix##*/}" = aarch64-unix ]; then
    echo "fex: FEX_X87REDUCEDPRECISION=$FEX_X87REDUCEDPRECISION from $fex_from" >> "$log" 2>&1 || true
  else
    echo "avx: ROSETTA_ADVERTISE_AVX=$ROSETTA_ADVERTISE_AVX from $avx_from" >> "$log" 2>&1 || true
  fi
  without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
  without_lock_fds "$WINESERVER" -w >> "$log" 2>&1 || true
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
  stage_step="variant modules"
  np_variant_stage_prefix
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

install_metalfx_dlls() {
  [ "${D3DM_ENABLE_METALFX:-0}" = 1 ] || return 0
  [ "${CX_GRAPHICS_BACKEND:-d3dmetal}" = d3dmetal ] || return 0
  sys32="$WINEPREFIX/drive_c/windows/system32"
  [ -d "$sys32" ] || return 0
  for dll in nvngx.dll nvapi64.dll; do
    src=""
    for dir in \
      "$CX_ROOT/lib64/apple_gptk/wine/x86_64-windows" \
      "$CX_ROOT/lib/apple_gptk/wine/x86_64-windows" \
      "$CX_ROOT/lib/wine/x86_64-windows" \
      "$CX_ROOT/lib/dxmt/x86_64-windows"; do
      if [ -f "$dir/$dll" ]; then
        src="$dir/$dll"
        break
      elif [ "$dll" = "nvngx.dll" ] && [ -f "$dir/nvngx-on-metalfx.dll" ]; then
        src="$dir/nvngx-on-metalfx.dll"
        break
      fi
    done
    [ -n "$src" ] || continue
    dst="$sys32/$dll"
    cmp -s "$src" "$dst" && continue
    if cp -fp "$src" "$dst" 2>> "$log"; then
      echo "=== installed MetalFX $dll into system32 ===" >> "$log" 2>&1 || true
    fi
  done
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
    b=${f##*/}
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
    base=${f##*/}
    case " $bridge_files " in
      *" $base "*) ;;
      *) rm -f "$f" && echo "=== pruned stale $base ===" >> "$log" 2>&1 ;;
    esac
  done
  # Needed for CEG 'platform survey'.
  mkdir -p "$WINEPREFIX/drive_c/windows/system32/config" 2>/dev/null || true
  verify_runner
  if ! install_lsteamclient_trigger; then
    show_alert "Steam files could not be copied" "NotProton could not copy a file into this game's prefix. Open this prefix's notproton-run.log for details."
    exit 1
  fi
  install_legacy_steam_dll
  install_metalfx_dlls
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
(
  set --
  for f in "$wine_unix"/*; do
    [ -e "$f" ] || continue
    base=${f##*/}
    case "$base" in
      wine|wine.app) continue ;;
    esac
    set -- "$@" "$f"
  done
  [ "$#" -eq 0 ] || ln -sfn "$@" "$loader_macos/"
)
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
exec "$WINELOADER" "\$@"
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
bundle_matches() {
  if [ -x "$np_support/appinfo" ]; then
    if "$np_support/appinfo" --same-bundle "$1" "$2" 2>/dev/null; then
      return 0
    else
      case "$?" in 1) return 1 ;; esac
    fi
  fi
  [ "$(bundle_listing "$1")" = "$(bundle_listing "$2")" ]
}
install_bundle() (
  exec 7>> "$loader_root/.lock"
  /usr/bin/lockf -s -t 30 7 || exit 1
  same=""
  for b in "$loader_root"/*.app; do
    if [ "$b" = "$loader_app" ] && [ -d "$b" ] && [ ! -L "$b" ] &&
       bundle_matches "$b" "$loader_stage"; then
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

# What this launch sets itself, which neither a plugin's env nor a NOTPROTON_ENV_ option
# may replace. One list for both, so the two ways of setting a variable cannot differ.
np_env_reserved() {
  case "$1" in
    (DYLD_* | PATH | HOME | CX_ROOT | CX_HOME | CX_APPLEGPTK_LIBD3DSHARED_PATH | STEAM_COMPAT_* | \
     STEAM_DYLD_INSERT_LIBRARIES | WINEPREFIX | WINELOADER | WINESERVER | WINEDLLPATH | \
     WINEDLLOVERRIDES | WINEMSYNC | NOTPROTON_*)
      return 0 ;;
  esac
  return 1
}

np_feat_dir="$np_support/plugins"
np_feat_log() {
  echo "=== $* ===" >> "$log" 2>&1 || true
}
# One reader for plugins and variants alike: the grammar, the limits and every refusal
# are in np_conf_normalise, and webpatch.c is checked against the same corpus.
np_conf_feat_table=$(np_conf_normalise "$np_feat_dir" "" plugin) || np_conf_feat_table=""
np_conf_log "$np_conf_feat_table" plugins

np_feat_first() {
  np_conf_value "$np_conf_feat_table" "$1" "$2"
}
# The first file a plugin names that is actually there; relative ones hang off $HOME.
np_feat_requires() {
  np_conf_values "$np_conf_feat_table" "$1" requires | while IFS= read -r np_feat_req; do
    np_feat_req=$(np_home_path "$np_feat_req")
    [ -f "$np_feat_req" ] && { printf '%s' "$np_feat_req"; break; }
  done
}
np_feat_installed() {
  [ -z "$(np_feat_first "$1" requires)" ] || [ -n "$(np_feat_requires "$1")" ]
}
np_feat_switched() {
  eval "np_feat_sv=\${$1-}"
  if [ -n "$(np_feat_first "$1" type)" ]; then
    # shellcheck disable=SC2154 # eval assigns np_feat_sv above
    [ -n "$np_feat_sv" ]
    return
  fi
  np_feat_son=$(np_feat_first "$1" on)
  [ "$np_feat_sv" = "${np_feat_son:-1}" ]
}
# A plugin may name the tools it is for, as a name or a name ending in "*". Naming none
# means every tool, which is what nearly all of them want.
np_feat_for_tool() {
  np_feat_tl=$(np_conf_values "$np_conf_feat_table" "$1" tools)
  [ -n "$np_feat_tl" ] || return 0
  while IFS= read -r np_feat_pat; do
    [ -n "$np_feat_pat" ] || continue
    # shellcheck disable=SC2254 # the pattern is a glob on purpose, and conf.c keeps it to one *
    case "$np_tool_name" in
      ($np_feat_pat) return 0 ;;
    esac
  done <<NP_FEAT_TOOLS
$np_feat_tl
NP_FEAT_TOOLS
  return 1
}

# A row is on only if everything it hangs off is, so a sub-option cannot outlive its parent.
np_feat_active() {
  [ "$2" -le 32 ] || return 1
  np_conf_has "$np_conf_feat_table" "$1" || return 1
  np_feat_for_tool "$1" || return 1
  np_feat_switched "$1" || return 1
  np_feat_installed "$1" || return 1
  np_feat_adep=$(np_feat_first "$1" depends)
  [ -z "$np_feat_adep" ] || np_feat_active "$np_feat_adep" $(($2 + 1))
}

np_feat_list=$(np_conf_ids "$np_conf_feat_table")

np_feat_dylibs=""
np_feat_envs=""
while IFS= read -r np_feat_key; do
  [ -n "$np_feat_key" ] || continue
  if ! np_feat_installed "$np_feat_key"; then
    np_feat_switched "$np_feat_key" &&
      np_feat_log "$np_feat_key is on but is skipped as $np_feat_key's required files are missing"
    continue
  fi
  np_feat_active "$np_feat_key" 0 || continue

  if [ "$(np_feat_first "$np_feat_key" inject)" = 1 ]; then
    np_feat_lib=$(np_feat_requires "$np_feat_key")
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

  np_feat_stage=$(np_feat_first "$np_feat_key" stage)
  if [ -n "$np_feat_stage" ]; then
    np_feat_stage=$(np_home_path "$np_feat_stage")
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

  np_feat_over=$(np_feat_first "$np_feat_key" overrides)
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
    if np_env_reserved "${np_feat_env%%=*}"; then
      np_feat_log "$np_feat_key skips env ${np_feat_env%%=*} as the compat_run script sets it"
      continue
    fi
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
$(np_conf_values "$np_conf_feat_table" "$np_feat_key" env)
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
  # A row hidden under this tool can't be switched off, so its value stays out too.
  if np_conf_has "$np_conf_feat_table" "NOTPROTON_ENV_$name" && ! np_feat_for_tool "NOTPROTON_ENV_$name"; then
    echo "=== NOTPROTON_ENV_$name is not for $np_tool_name, ignored ===" >> "$log" 2>&1 || true
    continue
  fi
  if np_env_reserved "$name"; then
    echo "=== NOTPROTON_ENV_$name would replace a setting this launch sets itself, ignored ===" \
      >> "$log" 2>&1 || true
    continue
  fi
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
registered="$loader_root/.launchservices-registered"
if [ ! -f "$registered" ] || [ "$loader_app/Contents/Info.plist" -nt "$registered" ]; then
  if [ -x "$lsregister" ] && "$lsregister" -f "$loader_app" >> "$log" 2>&1; then
    touch "$registered" 2>/dev/null || true
  fi
fi
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
