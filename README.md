# NotProton

NotProton enables the Steam Play experience from Linux Steam in the macOS Steam client.

This is done by forcibly enabling the Steam Play functionality in macOS Steam (which is
present and inert) as well as by porting some components of Valve's Proton to macOS.

This tool is intended to be used with Steam Client 1788652215 or 1790121765 and **CrossOver Preview
20261006 or 20260821**. Both the FEX build and the Rosetta build are supported. The Rosetta build is
the recommended version, as the FEX one is an early state.

## macOS 15 compatibility

The app and native components target **macOS 15.0 or later on Apple Silicon**.
The x86_64 slice of `notproton.dylib` is only a stub; this does not add Intel Mac
support.

On macOS 15, use the combined **CrossOver Preview 20261006** distribution.
NotProton automatically selects its bundled **Rosetta** runtime; a separate
Rosetta download is not needed. The ARM/FEX loader requires the 4 KB page-size
API introduced in macOS 26. Hosts with that API keep the existing FEX selection.
The Rosetta profile has separate, pinned ntdll patches and a runtime-selection
marker so the app, Steam launcher, Wine server, and bridge use the same architecture.

If switching an existing installation from FEX, quit Steam and NotProton, open
the updated app, and run **Set Up Compatibility Tool** followed by **Install**
from the Setup menu. The active build should read **20261006 Rosetta (bundled)**.
Rebuild FEX-created prefixes using the backup option before launching games;
do not delete the prefixes or backups until you have checked your saves.

### Building

Building requires Swift 6.1 or later (Xcode 16.4 Command Line Tools work on macOS
15), Python 3, CMake, and the bridge's MinGW, Bison, and Flex dependencies.
Command Line Tools-only builds use a conventional `.icns` icon. A full Xcode
installation with a macOS 26 or newer SDK also builds the layered Icon Composer
asset, retaining the `.icns` fallback for macOS 15. Use `ICON_COMPOSER=0` to force
the legacy-only icon build.

```sh
brew install cmake mingw-w64 bison flex
git clone https://github.com/jmpews/Dobby.git vendor/dobby
git -C vendor/dobby checkout 5dfc8546954ce3b3198132ab13fddb89ee92cdd7
make dobby
make bridge
make app
```

The resulting bundle is `out/NotProton.app`; `make app-zip` also produces
`out/NotProton.zip`. Packaging checks every bundled Mach-O architecture's
declared minimum OS version, including the Wine bridge and Sparkle. This is a
deployment-target check, not a substitute for testing the runtime on macOS 15.
Rebuild native components and Wine bridge trees previously compiled for a newer
deployment target; lowering `Info.plist` alone does not make binaries compatible.

### Validation

`make app-tests` runs the Swift suites after the payload has been staged.
`make deploymentcheck-tests` tests the packaging validator without external
dependencies. CI also compiles the app with Xcode 16.4's Swift 6.1 toolchain.

The bundled Rosetta integration test is opt-in. It requires an activated,
supported Preview installation and copies it into a temporary runner, verifies
both ntdll patches, then boots a fresh prefix and runs 64-bit and 32-bit Windows
commands. It does not modify the installed CrossOver, active runner, or game prefixes.

```sh
NOTPROTON_TEST_BUNDLED_ROSETTA=1 \
  swift test --package-path app --no-parallel --filter RealBundledRosettaTests
```

Set `NOTPROTON_TEST_CROSSOVER` to use a nonstandard CrossOver app path and
`NOTPROTON_TEST_TEMP` to choose the temporary directory. To reproduce the
bundled Rosetta detours from the installed Preview, install Python's `capstone`
module in your development environment and run:

```sh
FLAVOR=bundled-rosetta-41069 ntdll-patch/build-ntdll.sh
```

The script verifies the input, payload, and patched output hashes. Do not adopt
new hashes without validating the resulting runtime and Steam bridge.

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
