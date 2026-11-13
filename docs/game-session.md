# Single game icon

Game bundles use a native host to keep one game icon in the Dock and application
switcher. Wine UI processes remain interactive accessory applications. Selecting
the game icon activates the first visible window belonging to that session.
Quitting the host stops its Wine prefix. If the host is force quit, the existing
`open -W` watcher in the compatibility script performs prefix cleanup.

`make game-session` builds universal arm64 and x86_64 helpers. `make app-payload`
packages them with the bridge, and the app installs them through `BridgePayload`.
`make helpers-install` also installs them for local development. Game bundles copy
the helpers into `Contents/MacOS`; the Wine child script preserves the overlay and
plugin library settings before adding the session client library.

The compatibility script falls back to the existing Wine launcher when either
helper is unavailable. Set `NOTPROTON_SINGLE_GAME_ICON=0` in a game's launch
options to use that launcher explicitly. `NOTPROTON_HIDE_LAUNCHER_TILE=1` still
hides the game host's icon.

`make game-session-check` covers fallback staging, universal binaries, argument
forwarding, accessory activation, and prefix-scoped shutdown using a native test
client. It does not require Wine or Steam. The host changes macOS application
ownership; automatic Game Mode behavior and third-party window switchers need
separate validation on the target system.
