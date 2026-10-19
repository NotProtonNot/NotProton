# NotProton

NotProton enables the Steam Play experience from Linux Steam in the macOS Steam client.

This is done by forcibly enabling the Steam Play functionality in macOS Steam (which is
present and inert) as well as by porting some components of Valve's Proton to macOS.

This tool is intended to be used with the stable Steam Client (version 1791918634) as well as the beta Steam Client (version 1792192922) paired with **CrossOver 26.3 or CrossOver [Preview](https://www.codeweavers.com/preview)
20261006 / 20260821 / 20261015**, or a supported Whisky runtime as described below.

**NTFS file systems/drivers are not currently supported.**

This fork also supports **WhiskyWine winecx-gptk 4.7.54** and runtimes that declare native
`lsteamclient` support in `WhiskyWineVersion.plist`. Other builds require their own verified
ntdll and detour pins before they can be used. CrossOver support and its license requirements
remain available; a Whisky runtime does not require CrossOver or a CrossOver license.

The app discovers runtimes in Whisky and WhiskyPreview's Application Support folders. Use
**Choose Whisky Runtime…** for a runtime stored elsewhere, then **Set Up**. NotProton copies
the runtime into `~/Library/Application Support/notproton/runners/` using an APFS clone when
available, leaving Whisky's source runtime untouched. Each runtime gets its own Steam
compatibility tool. Whisky is preferred for games without an explicit tool selection;
existing per-game selections remain in place.

For Whisky, Properties > Compatibility can select D3DMetal (the default), WineD3D, DXVK,
or DXMT. DXVK and DXMT must be included in the runtime. Their native DLLs are staged into
the game's prefix while selected, and the original DLLs are restored when switching away.

For CrossOver, both the FEX and the Rosetta versions are supported. I recommend using the FEX version of the
Preview 20261006, as it includes both the FEX version as well as the Rosetta one. 

For CrossOver, I further recommend going into Steam Settings - Compatibility and selecting the Rosetta version as your default compatibility tool. You can select FEX on a per game basis by right clicking a game in Steam, going into Properties - Compatibility and selecting FEX there.

If a game has a native macOS version as well as a Windows one, Steam will download the macOS version. To override this behavior, right click on the game, select Properties, select Compatibility. Enable 'Force the use of a specific Steam Play compatibility tool'. Select the Whisky or CrossOver compatibility tool you want to use. That will make Steam download the Windows version. Unchecking the 'Force the use...' box or selecting 'No Compatibility Tool' in the drop down list will revert to the macOS version of the game, with the specifics there varying based on your Steam version.

**Valve Anti-Cheat is not supported.** Proton itself does not support VAC in Valve titles; Valve ships native Linux ports instead. VAC titles will launch in Insecure Mode and will not allow matchmaking. 

**This project now has a brew cask.** For brew users, you can install via ``brew install --cask notprotonnot/notproton/notproton``

Please read NOTICE for license information.

Please open issue reports with any issues. PRs are welcome and encouraged.

There are many people who worked on similar ideas, similar projects. I did not base NotProton on their work, but I still want to 
give thanks to the people who came before me:

[Nat Brown](https://github.com/natbro) made [Kaon](https://github.com/natbro/kaon), which is similar in goals to NotProton.

mont127's [Neutron](https://github.com/mont127/Neutron) is also a similar idea, but implemented differently. 

[Gio](https://github.com/giodotblue) was working enabling Steam Play inside of Steam on macOS prior to the release of NotProton itself. 
I would have done things differently had I been aware of that. 

Thanks to everyone who has positively contributed to macOS gaming. 

Developer Notes:

As far as the source structure goes, the macOS app itself is located in the ```app``` folder. The core logic is in ```dylib```.
```lsteamclient``` is a macOS port of Valve's lsteamclient. ```steam-shim```is a port of Valve's
steam-helper from Proton 9.0. ntdll-patch patches the copy of the runtime that the app
makes/places in the ```~/Library/Application Support/notproton/runners/``` folder so that
lsteamclient is loaded. Whisky runtimes with native `lsteamclient` support skip the detour.
