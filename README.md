# displayctl

[Русская версия](README.ru.md)

Current release: [displayctl 1.0.2](https://github.com/VitaliyYakob/displayctl/releases/tag/v1.0.2).
Download the ready-to-run Apple silicon archive and `SHA256SUMS` from the
release page. See the [English changelog](CHANGELOG.md) or
[Описание изменений на русском](CHANGELOG.ru.md).

`displayctl` is a Swift command-line utility for inspecting and controlling
Apple Studio Display and Apple Studio Display XDR on macOS.

It talks directly to CoreGraphics and dynamically loaded macOS display
frameworks. It does not open System Settings or emulate mouse clicks.

This application was created with OpenAI Codex under the direction of the
project author, who defined the requirements and tested its behavior on real
Apple displays.

## Features

- Lists connected supported displays and assigns stable ordinals for the
  current invocation.
- Shows display role, CoreGraphics ID, serial number, firmware, mirroring,
  current reference preset, refresh rate, Retina resolution, brightness,
  automatic brightness, True Tone, and Night Shift.
- Lists and changes reference presets, refresh rates, and the five native
  Studio Display Retina scales.
- Supports manual brightness (`1...100`) and automatic brightness (`auto`).
- Changes several displays independently in one command.
- Reads and changes display layout, including the main display and relative or
  absolute positions.
- Enables and disables mirroring with the main display as the source.
- Supports structured JSON output and non-destructive `--dry-run` validation.
- Uses Russian output when Russian is the primary macOS language and English
  for every other primary language.

## Requirements

- macOS 13 or later.
- Xcode Command Line Tools with Swift 5.9 or later, when building from source.
- Apple Studio Display or Apple Studio Display XDR.

The project has been developed and tested on Apple silicon with current macOS
display frameworks. Private framework compatibility can change after a major
macOS update; see [Implementation notes](#implementation-notes).

## Build

Install Xcode Command Line Tools if needed:

```sh
xcode-select --install
```

Build the release executable:

```sh
swift build -c release
```

Run it directly:

```sh
./.build/release/displayctl --version
./.build/release/displayctl
```

Optionally install it system-wide:

```sh
sudo install -m 0755 .build/release/displayctl /usr/local/bin/displayctl
```

After installation, open a new Terminal window and run `displayctl` from any
directory.

Run the regression tests:

```sh
swift test
```

The tests use fixtures and local subprocesses; they do not change connected
display settings.

## Quick start

```sh
# Short list of connected displays
displayctl
displayctl list

# Information and available values
displayctl info
displayctl info --all
displayctl profiles --display 1
displayctl rates --display 1
displayctl res --display 1
displayctl bright --all
displayctl layout

# Change the main display
displayctl set --profile 14 --rate 3 --res default --bright 50

# Enable automatic brightness
displayctl set --bright auto

# Apply defaults to every supported display
displayctl set --all --profile default --rate default --res default

# Change two displays independently
displayctl set \
  --display 1 --profile 4 --rate 2 --bright auto \
  --display 2 --profile 2 --bright 50

# Make display 2 the main display
displayctl set --layout --main 2

# Place display 2 to the right of display 1
displayctl set --layout --display 2 --right-of 1

# Enable mirroring on all secondary displays
displayctl mirroring on
```

Run `displayctl help` for the complete localized command reference.

## Display selection

`NUMBER` after `--display` is the ordinal printed by `displayctl list`, not a
CoreGraphics display ID or serial number.

Read commands accept repeated selectors:

```sh
displayctl info --display 2 --display 3
displayctl profiles --display 1 --display 2
```

Without `--display` or `--all`, `profiles`, `rates`, `res`, and `bright` operate
on the main display. `info` and `layout` show all supported displays by default.

`--all` and `--display` cannot be used together.

## Changing display settings

The `set` command accepts:

| Option | Value | Meaning |
| --- | --- | --- |
| `--profile` | `NUMBER` or `default` | Reference preset |
| `--rate` | `NUMBER` or `default` | Refresh rate |
| `--res` | `NUMBER` or `default` | Retina resolution |
| `--bright` | `1...100` or `auto` | Manual or automatic brightness |
| `--truetone` | `on` or `off` | Global True Tone state |
| `--nightshift` | `on` or `off` | Global Night Shift state |

A numeric brightness value disables automatic brightness before applying the
percentage. `--bright auto` enables automatic brightness. Some reference
presets disable brightness controls; unsupported changes are skipped with an
informational message.

When several `--display` blocks are used, each setting belongs to the closest
preceding display:

```sh
displayctl set \
  --display 1 --profile 4 --rate 2 \
  --display 2 --profile 2
```

True Tone and Night Shift are global graphical-session settings, so they are
applied once regardless of display selectors.

## Refresh rates and resolutions

For Studio Display XDR, `--rate default` selects Adaptive Sync when it is
available. Studio Display exposes its fixed native 60 Hz rate; attempts to
change it are skipped without failing the rest of the command.

`displayctl res` exposes only the five native 2× Retina scales:

- 1600×900
- 2048×1152
- 2560×1440
- 2880×1620
- 3200×1800

`--res default` selects the driver-recommended mode, with 2560×1440 at 2× as a
defensive fallback.

## Layout

`displayctl layout` is read-only. Layout changes are routed through `set`:

```sh
displayctl set --layout --main 2
displayctl set --layout --display 2 --position 2560,0
displayctl set --layout --display 2 --left-of 1
displayctl set --layout --display 2 --right-of 1
displayctl set --layout --display 2 --above 1
displayctl set --layout --display 2 --below 1
```

Layout changes are stored in one CoreGraphics transaction. Disable mirroring
before changing the layout. `--layout` cannot be combined with other `set`
changes in the same invocation.

## Mirroring

```sh
displayctl mirroring
displayctl mirroring on
displayctl mirroring off
displayctl mirroring on --display 2 --display 3
```

Without selectors, the change applies to all secondary supported displays. The
main display is always the source and must not be passed as a target.

## JSON and dry run

Add `--json` to any documented command for stable machine-readable output:

```sh
displayctl info --all --json
displayctl set --bright auto --json
```

Use `--dry-run` with changing commands to resolve selectors and values without
applying them:

```sh
displayctl set --profile 4 --rate 2 --dry-run
displayctl set --layout --main 2 --dry-run
displayctl mirroring on --dry-run
```

## Implementation notes

Display enumeration, video-mode changes, layout, and mirroring use public
CoreGraphics APIs. Reference presets, Adaptive Sync metadata, brightness,
automatic brightness, True Tone, Night Shift, and some display metadata use
CoreDisplay, SkyLight, DisplayServices, and CoreBrightness symbols that Apple
does not publish as a Swift API.

Those symbols are loaded at runtime. If an interface is absent or the active
reference preset disables a feature, the utility reports the limitation rather
than crashing. Compatibility should still be verified after major macOS
updates.

`info` keeps reporting available properties when a profile, refresh-rate, or
resolution table cannot be read. The failed table is empty and the reason is
shown in text output or an optional `warnings` array in JSON. Firmware lookup
has a five-second timeout and omits metadata when a display cannot be matched
unambiguously.

Reference presets and CoreGraphics video modes do not share one system
transaction. Changing both may therefore blank the displays twice, matching
the behavior of System Settings.

## Project structure

```text
App/displayctl/       Swift source files
Tests/DisplayctlTests/ Regression tests
releases/<version>/  Local release executable, archive, and checksum (ignored by Git)
Package.swift         Swift Package Manager manifest
.github/workflows/    GitHub Actions build and test verification
README.ru.md          Russian documentation
```

## Disclaimer

This is an independent project and is not affiliated with or endorsed by
Apple Inc. Apple, macOS, Studio Display, and XDR are trademarks of Apple Inc.
