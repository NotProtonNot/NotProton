# NotProton

NotProton brings the Linux Steam Play experience to the macOS Steam client.

It enables the Steam Play functionality that is present but inactive in macOS Steam and ports some components of Valve’s Proton to macOS.

## Contents

[Compatibility](#compatibility) | [Installation](#installation) | [Configuration](#configuration) | [Limitations](#limitations) | [Development](#development) | [Contributing](#contributing) | [Acknowledgments](#acknowledgments) | [License](#license)

## Compatibility

Use one of the following Steam clients together with a supported CrossOver version:

| Component | Supported versions |
| --- | --- |
| Steam Client — Stable | `1788652215` |
| Steam Client — Beta | `1791686101` |
| CrossOver | `26.3` |
| CrossOver Preview | `20261006` or `2026082` |

More supported versions are planned.

Both **FEX** and **Rosetta** are supported. The recommended download is the **FEX version of CrossOver Preview `20261006`**, which includes both FEX and Rosetta versions.

### CrossOver support

Supporting CrossOver specifically is a design goal of this project. Support for alternatives to CrossOver is not planned.

Improved support for modifying CrossOver is planned for a future update, including:

- Custom builds of DXMT.
- Patched D3DMetal.
- MacGameVideoFix.

## Installation

Download the latest version from [GitHub Releases](https://github.com/NotProtonNot/NotProton/releases/latest), or install it using Homebrew below.

### Homebrew

Install NotProton using the Homebrew cask:

```sh
brew install --cask notprotonnot/notproton/notproton
```

## Configuration

### Set the default compatibility tool

Rosetta is recommended as the default compatibility tool:

1. Open **Steam → Settings → Compatibility**.
2. Select the **Rosetta** version as your default compatibility tool.

### Use FEX for a specific game

1. Right-click the game in your Steam library.
2. Open **Properties → Compatibility**.
3. Enable **Force the use of a specific Steam Play compatibility tool**.
4. Select the **FEX** version.

### Install the Windows version of a game

If a game has both macOS and Windows versions, Steam downloads the macOS version by default. To install the Windows version instead:

1. Right-click the game in your Steam library.
2. Open **Properties → Compatibility**.
3. Enable **Force the use of a specific Steam Play compatibility tool**.
4. Select your preferred CrossOver version.

Steam will then download the Windows version of the game.

To switch back to the macOS version, uncheck **Force the use of a specific Steam Play compatibility tool** or select **No Compatibility Tool** from the drop-down list. The exact behavior depends on your Steam version.

## Limitations

> [!WARNING]
> **Valve Anti-Cheat (VAC) is not supported.** VAC titles launch in Insecure Mode and do not allow matchmaking.

Proton itself does not support VAC in Valve titles; Valve ships native Linux ports instead.

## Development

### Source structure

| Directory | Purpose |
| --- | --- |
| `app` | The macOS application. |
| `dylib` | Core logic. |
| `lsteamclient` | A macOS port of Valve’s `lsteamclient`. |
| `steam-shim` | A port of Valve’s `steam-helper` from Proton 9. |
| `ntdll-patch` | Patches the app’s copy of CrossOver so that `lsteamclient` is loaded. |

The app places its copy of CrossOver in:

```text
~/Library/Application Support/notproton/runners/
```

## Contributing

Please report problems through [GitHub Issues](https://github.com/NotProtonNot/NotProton/issues).

Pull requests are welcome and encouraged.

## Acknowledgments

Many people have worked on similar ideas and projects. Although NotProton is not based on their work, I want to thank those who came before me:

- **[Nat Brown](https://github.com/natbro)** created [Kaon](https://github.com/natbro/kaon), which shares similar goals with NotProton.
- **[mont127](https://github.com/mont127)** created [Neutron](https://github.com/mont127/Neutron), a similar idea with a different implementation.
- **[Gio](https://github.com/giodotblue)** worked on enabling Steam Play in Steam on macOS before NotProton was released. I would have done things differently had I been aware of that work.

Thanks to everyone who has positively contributed to macOS gaming.

## License

See [NOTICE](NOTICE) for license information.

