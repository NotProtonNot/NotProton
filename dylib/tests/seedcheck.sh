#!/bin/sh
set -eu
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
work=$(mktemp -d "${TMPDIR:-/tmp}/np-seedcheck.XXXXXX")
test "$(stat -f %d "$work")" = "$(stat -f %d "${TMPDIR:-/tmp}")"
trap 'chmod -R u+rwX "$work"; rm -rf "$work"' EXIT
cut_block() {
  from="$1" to="$2" keep="$3" awk '
    BEGIN { from = ENVIRON["from"]; to = ENVIRON["to"]; keep = ENVIRON["keep"] }
    !on && $0 ~ from { on = 1 }
    on && $0 ~ to { if (keep) print; found = 1; exit }
    on { print }
    END { exit !found }' "$SRC" || { echo "FAIL: no block from /$1/ to /$2/ in $SRC" >&2; exit 1; }
}
functions=$(cut_block '^merge_user_dir\(\) \{' '^import_prefix_settings\(\) \{' "")
functions="$functions
$(cut_block '^runner_id=""' '^if \[ -n ".STEAM_COMPAT_DATA_PATH" \]; then' "")"
functions="$functions
$(cut_block '^without_lock_fds\(\) \{' '^\}' 1)"
np_build=fixture
np_variant_key=""
export np_variant_key np_build CX_ROOT CX_HOME wine_unix np_tool_dir WINELOADER WINESERVER
export STEAM_COMPAT_DATA_PATH WINEPREFIX template_dir log seed_scratch seed_building
CX_ROOT="$work/runner"
CX_HOME="$work/home"
wine_unix="$CX_ROOT/lib/wine/x86_64-unix"
np_tool_dir="$work/tool"
mkdir -p "$np_tool_dir" "$CX_ROOT/share/wine"
cp "$SRC" "$np_tool_dir/run"
printf inf > "$CX_ROOT/share/wine/wine.inf"
WINELOADER=/usr/bin/false
WINESERVER=/usr/bin/false
eval "$functions"
fails=0
check() {
  if "$@"; then printf '  ok %s\n' "$*"; else
    printf '  FAIL %s\n' "$*"
    fails=$((fails + 1))
  fi
}
fixture() {
  case_root=$(mktemp -d "$work/case.XXXXXX")
  STEAM_COMPAT_DATA_PATH="$case_root/game"
  WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  template_dir="$case_root/template"
  log="$case_root/log"
  seed_scratch=""
  seed_building=0
  mkdir -p "$WINEPREFIX" "$template_dir/pfx/drive_c/windows"
  printf reg > "$template_dir/pfx/system.reg"
  printf reg > "$template_dir/pfx/user.reg"
  printf reg > "$template_dir/pfx/userdef.reg"
  printf timestamp > "$template_dir/pfx/.update-timestamp"
  printf dll > "$template_dir/pfx/drive_c/windows/ntdll.dll"
  lay_out_proton_profile "$template_dir/pfx"
}

fixture
profile="$WINEPREFIX/drive_c/users/steamuser"
mkdir -p "$profile/Documents/Game" "$profile/My Documents/Game"
printf marker > "$profile/Documents/Game/steam_autocloud.vdf"
printf save > "$profile/My Documents/Game/slot.sav"
lay_out_proton_profile
check test -f "$profile/Documents/Game/slot.sav"
printf newer > "$profile/Documents/Game/slot.sav"
check lay_out_proton_profile
check test "$(cat "$profile/Documents/Game/slot.sav")" = newer

fixture
printf original > "$WINEPREFIX/drive_c"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused

fixture
mkdir -p "$case_root/external" "$WINEPREFIX/drive_c/users"
ln -s "$case_root/external" "$WINEPREFIX/drive_c/users/steamuser"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser"
chmod 000 "$WINEPREFIX/drive_c/users/steamuser"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused
chmod 700 "$WINEPREFIX/drive_c/users/steamuser"

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf save > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
before=$(stat -f %i "$WINEPREFIX")
copy_template_into_prefix
check test "$before" = "$(stat -f %i "$WINEPREFIX")"
check test -f "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
check test -f "$WINEPREFIX/.update-timestamp"
check test -f "$WINEPREFIX/system.reg"
check test ! "$template_dir/pfx/drive_c/windows/ntdll.dll" -ef "$WINEPREFIX/drive_c/windows/ntdll.dll"
printf changed > "$WINEPREFIX/drive_c/windows/ntdll.dll"
check test "$(cat "$template_dir/pfx/drive_c/windows/ntdll.dll")" = dll

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf save > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
interrupted_status=0
env functions="$functions" /bin/sh -c "
  eval \"\$functions\"
  ln() { command ln \"\$@\"; kill -KILL \"\$\$\"; return 1; }
  copy_template_into_prefix
" || interrupted_status=$?
check test "$interrupted_status" -eq 137
check test -f "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
check test ! -e "$WINEPREFIX/.update-timestamp"
check test ! -e "$WINEPREFIX/system.reg"
for abandoned in "$STEAM_COMPAT_DATA_PATH"/pfx.seeding.*; do
  check test -d "$abandoned"
  seed_prefix_from_template
  check test ! -e "$abandoned"
done

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf save > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
interrupted_status=0
env functions="$functions" /bin/sh -c "
  eval \"\$functions\"
  ln() { command ln \"\$@\"; kill -TERM \"\$\$\"; return 1; }
  trap 'abandon_seed 143' TERM
  copy_template_into_prefix
" || interrupted_status=$?
check test "$interrupted_status" -eq 143
check test -f "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/slot.sav"
check test ! -e "$WINEPREFIX/.update-timestamp"

fixture
mkdir -p "$template_dir/pfx.building.$$"
printf partial > "$template_dir/pfx.building.$$/system.reg"
rm -rf "$template_dir/pfx"
check test "$(build_prefix_template && echo accepted || echo refused)" = refused
check test ! -e "$template_dir/pfx"

fixture
profile="$WINEPREFIX/drive_c/users/steamuser"
mkdir -p "$profile/Documents/Game" "$profile/My Documents/Game"
printf modern > "$profile/Documents/Game/slot.sav"
printf legacy > "$profile/My Documents/Game/slot.sav"
check test "$(lay_out_proton_profile && echo accepted || echo refused)" = refused
check test "$(cat "$profile/Documents/Game/slot.sav")" = modern
check test "$(cat "$profile/My Documents/Game/slot.sav")" = legacy
check test ! -L "$profile/My Documents"

fixture
profile="$WINEPREFIX/drive_c/users/steamuser"
mkdir -p "$profile/Documents/Game" "$profile/My Documents BACKUP/Game"
ln -s ./Documents "$profile/My Documents"
printf save > "$profile/My Documents BACKUP/Game/slot.sav"
lay_out_proton_profile
check test ! -e "$profile/Documents/Game/slot.sav"
check test -f "$profile/My Documents BACKUP/Game/slot.sav"

fixture
mkdir -p "$STEAM_COMPAT_DATA_PATH/pfx.seeding.$$"
printf stale > "$STEAM_COMPAT_DATA_PATH/pfx.seeding.$$/system.reg"
copy_template_into_prefix
check test ! -e "$WINEPREFIX/system.reg"
check test "$(cat "$STEAM_COMPAT_DATA_PATH/pfx.seeding.$$/system.reg")" = stale
check test ! -e "$STEAM_COMPAT_DATA_PATH/pfx.seeding.$$/pfx"

fixture
profile="$WINEPREFIX/drive_c/users/steamuser"
mkdir -p "$profile/Documents" "$profile/My Documents BACKUP/Game"
ln -s ./Documents "$profile/My Documents"
ln -s "$case_root/offline" "$profile/Documents/Game"
printf historical > "$profile/My Documents BACKUP/Game/slot.sav"
check lay_out_proton_profile
check test -L "$profile/Documents/Game"
check test "$(readlink "$profile/Documents/Game")" = "$case_root/offline"

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf original > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/save"
(
  eval 'cp() { return 1; }'
  copy_template_into_prefix
)
check test "$(cat "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/save")" = original
check test ! -e "$WINEPREFIX/system.reg"

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser/Documents/Game"
printf original > "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/save"
(
  eval 'ln() { return 1; }'
  copy_template_into_prefix
)
check test "$(cat "$WINEPREFIX/drive_c/users/steamuser/Documents/Game/save")" = original
check test ! -e "$WINEPREFIX/system.reg"

fixture
mkdir -p "$WINEPREFIX/dosdevices"
ln -s ../drive_c "$WINEPREFIX/dosdevices/c:"
ln -s / "$WINEPREFIX/dosdevices/z:"
check prefix_is_bare
ln -s /outside "$WINEPREFIX/dosdevices/d:"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused

fixture
mkdir -p "$WINEPREFIX/dosdevices" "$template_dir/pfx/dosdevices"
for dir in "$WINEPREFIX" "$template_dir/pfx"; do
  ln -s ../drive_c "$dir/dosdevices/c:"
  ln -s / "$dir/dosdevices/z:"
done
ln -s /library "$WINEPREFIX/dosdevices/s:"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused
printf '/elsewhere\n' > "$STEAM_COMPAT_DATA_PATH/notproton-game-drive"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused
printf '/library\n' > "$STEAM_COMPAT_DATA_PATH/notproton-game-drive"
check prefix_is_bare
copy_template_into_prefix
check test -f "$WINEPREFIX/system.reg"
check test "$(readlink "$WINEPREFIX/dosdevices/s:")" = /library
check test "$(readlink "$WINEPREFIX/dosdevices/c:")" = ../drive_c

fixture
mkdir -p "$WINEPREFIX/drive_c/users/steamuser"
mkfifo "$WINEPREFIX/drive_c/users/steamuser/fifo"
check test "$(prefix_is_bare && echo unsafe || echo refused)" = refused

fixture
export WINEDLLOVERRIDES=leak WINEARCH=win32 WINEMSYNC=1 SteamAppId=123
isolated=$(in_template_env "$WINEPREFIX" /usr/bin/env)
check test "$(printf '%s\n' "$isolated" | grep -Ec '^(WINEDLLOVERRIDES|WINEARCH|WINEMSYNC|SteamAppId)=' || true)" = 0

fixture
prepare_prefix_directory
probe_lock() {
  env functions="$functions" /bin/sh -c "
    exec 8>&- 9>&-
    eval \"\$functions\"
    prepare_prefix_directory && echo unlocked || echo locked
  "
}
check test "$(probe_lock)" = locked
exec 8>&-
check prepare_prefix_directory
exec 8>&-

cat > "$work/daemonize" <<'STUB'
#!/bin/sh
sleep 30 &
echo "$!" > "$1"
STUB
chmod +x "$work/daemonize"

fixture
prepare_prefix_directory
"$work/daemonize" "$case_root/leaked.pid"
exec 8>&-
check test "$(probe_lock)" = locked
kill "$(cat "$case_root/leaked.pid")" 2>/dev/null || true

fixture
prepare_prefix_directory
without_lock_fds "$work/daemonize" "$case_root/held.pid"
exec 8>&-
check test "$(probe_lock)" = unlocked
kill "$(cat "$case_root/held.pid")" 2>/dev/null || true

fixture
mkdir -p "$STEAM_COMPAT_DATA_PATH/pfx.replaced.123"
printf save > "$STEAM_COMPAT_DATA_PATH/pfx.replaced.123/save"
recovery_status=0
env functions="$functions" /bin/sh -ec "
  eval \"\$functions\"
  show_alert() { :; }
  prepare_prefix_directory
  : > \"\$STEAM_COMPAT_DATA_PATH/continued\"
" || recovery_status=$?
check test "$recovery_status" -eq 1
check test ! -e "$STEAM_COMPAT_DATA_PATH/continued"
check test -f "$STEAM_COMPAT_DATA_PATH/pfx.replaced.123/save"

fixture
identity_before=$(template_identity)
printf changed > "$CX_ROOT/share/wine/wine.inf"
check test "$identity_before" != "$(template_identity)"
identity_before=$(template_identity)
printf '\n' >> "$np_tool_dir/run"
check test "$identity_before" != "$(template_identity)"

export fake_initializer="in_template_env() (
  if [ \"\$3\" = wineboot ]; then
    mkdir -p \"\$1/drive_c/windows\"
    printf system > \"\$1/system.reg\"
    printf user > \"\$1/user.reg\"
    printf defaults > \"\$1/userdef.reg\"
    printf dll > \"\$1/drive_c/windows/ntdll.dll\"
    if [ -n \"\${ready_pipe:-}\" ]; then
      printf ready > \"\$ready_pipe\"
      read -r proceed < \"\$resume_pipe\"
    fi
    return \"\${fake_init_status:-0}\"
  fi
  return \"\${fake_wait_status:-0}\"
)"
eval "$fake_initializer"

fixture
rm -rf "$template_dir/pfx"
export fake_init_status=1
check test "$(build_prefix_template && echo accepted || echo refused)" = refused
check test ! -e "$template_dir/pfx"
fake_init_status=0
export fake_wait_status=1
check test "$(build_prefix_template && echo accepted || echo refused)" = refused
check test ! -e "$template_dir/pfx"
fake_wait_status=0

fixture
set -- dosbox.exe -conf '.\base\plutoniam.conf'
seed_prefix_from_template
check test -f "$WINEPREFIX/system.reg"
check test "$#" -eq 3
check test "$3" = '.\base\plutoniam.conf'
set --

fixture
seed_prefix_from_template
check test -f "$WINEPREFIX/system.reg"
check test -f "$template_dir/ready"
check test ! -e "$STEAM_COMPAT_DATA_PATH/pfx.replaced.$$"
first_prefix="$WINEPREFIX"
printf first-game > "$first_prefix/system.reg"
printf obsolete > "$template_dir/pfx/obsolete"
printf updated-inf > "$CX_ROOT/share/wine/wine.inf"
STEAM_COMPAT_DATA_PATH="$case_root/next-game"
WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
mkdir -p "$WINEPREFIX"
seed_prefix_from_template
check test "$(cat "$first_prefix/system.reg")" = first-game
check test "$(cat "$WINEPREFIX/system.reg")" = system
check test ! -e "$template_dir/pfx/obsolete"
check test ! -e "$WINEPREFIX/obsolete"

fixture
export ready_pipe="$case_root/ready" resume_pipe="$case_root/resume"
mkfifo "$ready_pipe" "$resume_pipe"
first_prefix="$WINEPREFIX"
env functions="$functions" /bin/sh -ec "
  eval \"\$functions\"
  eval \"\$fake_initializer\"
  prepare_prefix_directory
  seed_prefix_from_template
" &
builder=$!
read -r ready < "$ready_pipe" || true
check test "$ready" = ready
STEAM_COMPAT_DATA_PATH="$case_root/second"
WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
mkdir -p "$WINEPREFIX"
unset ready_pipe resume_pipe
seed_prefix_from_template
check test ! -e "$WINEPREFIX/system.reg"
printf 'continue\n' > "$case_root/resume"
wait "$builder"
check test -f "$first_prefix/system.reg"
seed_prefix_from_template
check test -f "$WINEPREFIX/system.reg"
check test "$(find "$template_dir/pfx" -name 'pfx.building.*' | wc -l | tr -d ' ')" = 0

fixture
chmod 500 "$case_root"
cache_status=0
env functions="$functions" /bin/sh -ec "
  eval \"\$functions\"
  eval \"\$fake_initializer\"
  seed_prefix_from_template
" || cache_status=$?
chmod 700 "$case_root"
check test "$cache_status" -eq 0
check test ! -e "$WINEPREFIX/system.reg"

fixture
: > "$case_root/.notproton-template.lock"
chmod 400 "$case_root/.notproton-template.lock"
cache_status=0
env functions="$functions" /bin/sh -ec "
  eval \"\$functions\"
  eval \"\$fake_initializer\"
  seed_prefix_from_template
" || cache_status=$?
chmod 600 "$case_root/.notproton-template.lock"
check test "$cache_status" -eq 0
check test ! -e "$WINEPREFIX/system.reg"

fixture
seed_prefix_from_template
printf stale > "$template_dir/ready"
chmod 500 "$template_dir"
STEAM_COMPAT_DATA_PATH="$case_root/second"
WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
mkdir -p "$WINEPREFIX"
cache_status=0
env functions="$functions" /bin/sh -ec "
  eval \"\$functions\"
  eval \"\$fake_initializer\"
  seed_prefix_from_template
" || cache_status=$?
chmod 700 "$template_dir"
check test "$cache_status" -eq 0
check test ! -e "$WINEPREFIX/system.reg"
check test "$(cat "$template_dir/ready")" = stale

printf 'seedcheck: %s failures\n' "$fails"
test "$fails" -eq 0
