# NotProton

NotProton enables the Steam Play experience from Linux Steam in the macOS Steam client.

This is done by forcibly enabling the Steam Play functionality in macOS Steam (which is
present and inert) as well as by porting some components of Valve's Proton to macOS.

This tool is intended to be used with Steam Client 1788652215 or 1790121765 and one of these
CrossOver builds:

- CrossOver 26.3 (26.3.0.39832)
- CrossOver Preview 20260821 (27.0.0.40921)
- CrossOver Preview 20261006 (27.0.0.41069)

For the Preview builds, both the FEX build and the Rosetta build are supported. The Rosetta
build is the recommended version, as the FEX one is in an early state.

A build is recognized by its Wine loader and ntdll, not by its name or folder. NotProton
looks in `/Applications`, `~/Applications`, one folder level inside either, the top level
and `Applications` folder of each mounted drive, and wherever Spotlight finds a CrossOver
bundle. **Add CrossOver…** covers any other location.

Copies of a supported build that other tools have changed also work:

- **GPTK Patcher Tool:** a copy with a newer Game Porting Toolkit or DXMT gets its own
  runner and Steam compatibility tools, named after what was put in, for example
  `CrossOver 26.3 · GPTK 4.0b2 · DXMT 0.80`. The stock toolkit the patcher keeps as
  `apple_gptk.stock` is offered as a separate runner.
- **Any copy:** a `notproton-variant` file in its `Contents/SharedSupport/CrossOver`
  folder names the copy, and it gets its own runner in the same way.
- **Graphics settings:** keys in the copy's `etc/CrossOver.conf` `[EnvironmentVariables]`
  section that start with `CX_GRAPHICS`, `D3DM_`, `DXMT_`, `DXVK_`, `MTL_` or `ROSETTA_`
  are applied to games. GPTK Patcher writes its MetalFX, NVEXT, frame cap and HUD settings
  there. A launch option for the same key takes priority.

CrossOver 25 is not supported.

The macOS app itself is located in the ```app``` folder. The core logic is in ```dylib```.
```lsteamclient``` is a macOS port of Valve's lsteamclient. ```steam-shim```is a port of Valve's
steam-helper from Proton 9. ntdll-patch patches the copy of CrossOver that the app
makes/places in the ```~/Library/Application Support/notproton/runners/``` folder so that
lsteamclient is loaded.

This release is coming several days past when I wanted to release it, so the
documentation is quite sparse. Sorry about that, I'll improve it over the next day or
two.

Please read NOTICE for license information.

Please open issue reports with any issues. PRs are welcome and encouraged.
