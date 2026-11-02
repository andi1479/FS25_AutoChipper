# FS25_AutoChipper

**Mod for Farming Simulator**

Farming Simulator 25 mod that chips loose wood lying around your wood chipper, so you don't have to drive around branches and crown pieces after felling trees.

Works with every wood chipper vehicle, e.g. the Heizomat HM 10-500 KF or the Jenz HEM 922 DQ Cobra hybrid, including modded chippers.

## Features

- Turn the chipper on and press **Left Alt + C** to enable auto chipping
- Loose cut pieces up to **5 m** within **15 m** of the chipper are hopped into the intake one by one and chipped
- Uses the game's own chipping logic: correct wood chip amount, sound and particles
- Wood chips leave through the pipe as usual - put a trailer under the pipe (the HM 10-500 KF has a rear hitch for a chip trailer)
- Standing trees, stumps, longer logs and logs on trailers or in cranes are left alone
- Multiplayer supported (all chipping runs on the server)

## Installation

Download `FS25_AutoChipper.zip` from the [latest release](../../releases/latest) and put it into
`Documents\My Games\FarmingSimulator2025\mods`. Do not unpack it.

Activate the mod for your savegame in the mod selection.

## Usage

1. Attach the chipper to a tractor and put a wood chip trailer under the pipe
2. Turn the chipper on
3. Press **Left Alt + C** - the F1 help shows "Auto chipper active"
4. Drive around - nearby pieces get chipped automatically

| Keyboard | Controller | Action |
|---|---|---|
| Left Alt + C | LB + RB + X | Enable / disable auto chipping |

The keys can be changed in the game's control settings ("Auto chip nearby wood").

## Settings

Radius, maximum piece length and timing are constants at the top of [`scripts/AutoChipper.lua`](scripts/AutoChipper.lua):

| Constant | Default | Meaning |
|---|---|---|
| `RADIUS` | 15 | Search radius around the chipper (m) |
| `MAX_LENGTH` | 5 | Longer pieces are left alone (m) |
| `MAX_HEIGHT_ABOVE_GROUND` | 1.5 | Ignore pieces on trailers / in cranes (m) |
| `HOP_DELAY` | 400 | Time a piece sits in the intake before it is chipped (ms) |
| `HOP_INTERVAL` | 600 | Time between two pieces (ms) |
| `DEBUG` | false | Log every chipped and skipped piece to `log.txt` |

## How it works

`scripts/AutoChipperRegister.lua` adds the `autoChipper` specialization to every vehicle type that has the base game `WoodCrusher` specialization. While enabled, `scripts/AutoChipper.lua` scans the area around the chipper with `overlapSphere`, picks the nearest valid piece, moves it into the intake and chips it the same way `WoodCrusher.crushSplitShape` does.

## Releasing

Releases are built automatically by GitHub Actions ([`.github/workflows/release.yml`](.github/workflows/release.yml)): bump `<version>` in `modDesc.xml` and push to `main`.

If there is no release for that version yet, the workflow zips `modDesc.xml`, the icon and `scripts/`, creates the tag `v<version>` and attaches `FS25_AutoChipper.zip` to a new GitHub release. Pushes that don't change the version don't create a release.
