# The compatibility runner owns both halves of the bridge for the game session.
# shellcheck shell=sh

discord_bridge_pid=""
discord_state=""

stop_discord_bridge() {
  if [ -n "$discord_bridge_pid" ]; then
    kill "$discord_bridge_pid" 2>/dev/null || true
    wait "$discord_bridge_pid" 2>/dev/null || true
    discord_bridge_pid=""
  fi
  if [ -n "$discord_state" ]; then
    rm -rf "$discord_state"
    discord_state=""
  fi
}

start_discord_bridge() {
  discord_root="$1/integrations/discord"
  discord_log="$3"
  if [ ! -x "$discord_root/host" ] || [ ! -f "$discord_root/notproton-discord.exe" ]; then
    echo "Discord bridge components unavailable" >> "$discord_log" 2>&1 || true
    return 0
  fi
  discord_state=$(mktemp -d "${TMPDIR:-/tmp}/notproton-discord.XXXXXX") || return 0
  # Start on the original Wine loader, before the game's bundle identity is applied.
  env -u DYLD_INSERT_LIBRARIES -u STEAM_DYLD_INSERT_LIBRARIES -u NOTPROTON_GAME_LOADER \
    "$discord_root/host" "$2" "$discord_root/notproton-discord.exe" \
    > "$discord_state/ready" 2>> "$discord_log" &
  discord_bridge_pid=$!
  discord_tick=0
  # Allow Wine the same ten-second startup window as the native host.
  while [ "$discord_tick" -lt 100 ] && kill -0 "$discord_bridge_pid" 2>/dev/null; do
    if grep -qx ready "$discord_state/ready"; then
      echo "Discord bridge ready" >> "$discord_log" 2>&1 || true
      return 0
    fi
    discord_tick=$((discord_tick + 1))
    sleep 0.1
  done
  echo "Discord bridge unavailable; continuing game launch" >> "$discord_log" 2>&1 || true
  stop_discord_bridge
}
