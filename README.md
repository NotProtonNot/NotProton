# NotProton

NotProton enables the Steam Play experience from Linux Steam in the macOS Steam client.

This is done by forcibly enabling the Steam Play functionality in macOS Steam (which is
present and inert) as well as by porting some components of Valve's Proton to macOS.

This tool is intended to be used with Steam Client 1788652215 or 1790121765 and **CrossOver Preview
2026082**. Both the FEX build and the Rosetta build are supported. The Rosetta build is
the recommended version, as the FEX one has generally worse compatibility with games.
D3DMetal is only available on the Rosetta build. On the FEX build, games set to D3DMetal
fall back to a different graphics backend.
It's early, that's all.

The macOS app itself is located in the ```app``` folder. The core logic is in ```dylib```.
```lsteamclient``` is a macOS port of Valve's lsteamclient. ```steam-shim```is a port of Valve's
steam-helper from Proton 9. ntdll-patch patches the copy of CrossOver that the app
makes/places in the ```~/Library/Application Support/notproton/runners/``` folder so that
lsteamclient is loaded.

This release is coming several days past when I wanted to release it, so the
documentation is quite sparse. Sorry about that, I'll improve it over the next day or
two.

Please read NOTICE for license information.

Please open issue reports with any issues.
