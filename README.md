# NotProton

NotProton enables the Steam Play experience from Linux Steam in the macOS Steam client.

This is done by forcibly enabling the Steam Play functionality in macOS Steam (which is
present and inert) as well as by porting some components of Valve's Proton to macOS.

This tool is intended to be used with Steam Client 1788652215 or 1790121765 and **CrossOver Preview
20261006 or 2026082**. Both the FEX build and the Rosetta build are supported. The Rosetta build is
the recommended version, as the FEX one is in an early state.

## Free Wine engine (no CrossOver needed)

NotProton can also run entirely on free software. Under Compatibility Tool, **Download & Set Up**
fetches the WineHQ 11.15 macOS build from [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds)
(hash pinned), unpacks it into `~/Library/Application Support/notproton/engines/` and sets the
compatibility tool up from it exactly like a CrossOver copy. No CrossOver license is involved; the
license check is skipped only for loaders whose hash pins the free build.

11.15 is chosen because it is the Wine the bridge components (`lsteamclient`, `steam.exe`) are built
against. Differences from CrossOver to be aware of:

- It is an x86_64 build and runs under Rosetta 2, like the Rosetta build of CrossOver.
- Direct3D 10/11 goes through [DXMT](https://github.com/3Shain/dxmt) (MIT), downloaded and pinned
  alongside Wine, which translates straight to Metal. Wine's own wined3d cannot reach feature level 11
  on macOS OpenGL. D3DMetal is Apple's and only works with CrossOver's Wine, so it is not used.
- DXMT needs macdrv functions upstream Wine hides; NotProton ships a rebuilt `winemac.so`
  that exports them (see `winemac-patch/`).
- D3D 12 has no fast path; vkd3d over the bundled MoltenVK is limited.
- WineHQ has no msync/esync, so CPU-heavy games can run slower than under CrossOver or Sikarugir.
- The graphics backend options in the Steam panel have no effect on this engine.

To support another WineHQ build, run `ntdll-patch/resolve.py` against its Wine tree, build the
payloads with `ntdll-patch/build.sh` / `build32.sh`, and add the hashes to `SupportedRunners`,
`NtdllPatcher.byBuild` and `FreeEngine`.

The macOS app itself is located in the ```app``` folder. The core logic is in ```dylib```.
```lsteamclient``` is a macOS port of Valve's lsteamclient. ```steam-shim```is a port of Valve's
steam-helper from Proton 9. ntdll-patch patches the copy of CrossOver that the app
makes/places in the ```~/Library/Application Support/notproton/runners/``` folder so that
lsteamclient is loaded.

This release is coming several days past when I wanted to release it, so the
documentation is quite sparse. Sorry about that, I'll improve it shortly.

Please read NOTICE for license information.

Please open issue reports with any issues. PRs are welcome and encouraged. Contributions policy to come shortly.
