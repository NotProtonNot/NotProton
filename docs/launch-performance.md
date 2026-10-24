# Launch preparation and Dock startup

The launcher checks completed Steam common-redist scripts and existing prefix settings before starting Windows helpers. Unsupported scripts, missing completion markers, changed settings, or failed Python checks follow the normal preparation path. The optional checks use the system Python 3 in isolated mode.

A completed install-script check starts Wine and SamSs in the background while Steam hands off to the game. It uses a command to trigger automatic Wine initialization once; explicitly running `wineboot --init` at this point starts a second service manager and can make SamSs initialization fail. Prefix lock descriptors are closed before starting persistent Wine processes. The generated macOS launcher replaces its shell with Wine using `exec`.

Correct font links are preserved. Bridge and launcher metadata caches are reused only while their dependencies and launch configuration match. Changed files invalidate the caches. LaunchServices registration is repeated when the installed bundle changes. The normal game-exit teardown still stops the prefix server.

`TIMING` records in `notproton-run.log` identify preparation stages and macOS bundle invocation. In local Subnautica 2 tests, bundle invocation to the main game process dropped from roughly four seconds to about one to two seconds. One normal relaunch reached the main game process in 9.98 seconds overall. These observations exclude loading the menu or a playable world and are not performance guarantees.

Run `make launchperfcheck settingscheck launchercheck bridgecheck routecheck gamedrivecheck envcheck buildcheck seedcheck` to exercise the fast paths and existing launcher behavior without launching Steam or Wine.
