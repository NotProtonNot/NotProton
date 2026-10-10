# Steam Input rumble in Wine

This adapter forwards the two motor values from Winebus's
`SDL_JoystickRumble` to the native Steam `SteamController008` interface.
It fixes the missing rumble backend for Steam's macOS virtual Xbox gamepad.
Games using the Steam Controller/Input API directly use their existing route.

The adapter is a universal Mach-O library injected into NotProton's Wine
processes. It intercepts Wine's dynamic SDL2 symbol lookup for symbols from
the selected CrossOver runtime.

A device qualifies only when its SDL GUID matches an IOKit device with
`Transport=Virtual`, `Manufacturer=Microsoft`, and `Product=GamePad-N`.
Both Darwin and HIDAPI SDL GUID signatures are supported. The corresponding
Steam gamepad index supplies the controller handle. Unknown devices use
original SDL.

One worker owns the native Steam API and forwards the latest motor values.
It handles effect expiry, explicit stops and device close. While an effect is
active, controller assignments are checked every 20 ms. A missing assignment
is retried until the effect expires; a changed assignment stops the previous
controller before forwarding to its replacement. A re-created SDL device
starts with an empty mailbox. Each slot retains the latest command, and Steam
handles output to the physical controller.

`rumble.cpp` owns SDL interception and the command mailbox. `VirtualGamepad.h`
validates the virtual device identity; `SteamSession.h` owns the native Steam
connection and releases partially initialized sessions on failure.

## Build and use

`make steam-rumble` builds the library; `make steam-rumble-check` tests routing,
SDL hook selection, virtual-device detection, reconnection, player indices,
amplitude preservation, expiry, reassignment, explicit stop, close, shutdown
and launch gating without controller output. The Steam mock implements the
SDK interfaces and rejects unexpected calls, including LED changes. Steamworks
headers are obtained through the project's pinned `lsteamclient/fetch.sh`.

The regular app payload includes `controllers/steam-input/rumble.dylib` and
installs/removes it with the other NotProton runtime components. The run script
enables it for game sessions with direct controller access disabled. To opt
out for a game, set `NOTPROTON_STEAM_RUMBLE=0 %command%` in Steam launch options.
`NOTPROTON_RAW_CONTROLLERS=1` also bypasses it, preserving direct DualSense PCM.
A missing adapter leaves the previous launch behavior intact.

## Validation and limits

Verified with CrossOver 26.3 / SDL 2.30.12 (Rosetta), native Steam Input,
INVERSUS Deluxe and a Bluetooth DualSense. The adapter logs the mapped
virtual slot and the first nonzero rumble forwarded from XInputSetState.

The binary includes arm64 for the FEX runtime, but gameplay under FEX and
multiple simultaneous physical controllers still need hardware validation.
