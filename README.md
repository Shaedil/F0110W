# F0110W

A MacCharlie-inspired plug-in module for the Apple Macintosh Keyboard (M0110)
that converts a M0110 to USB and Bluetooth, running ZMK firmware on Framework's
Control Board.

## Hardware

- Framework Control Board
- Apple M0110
- custom pcb with LiPo charging + boost, logic-level conversion, radar gesture
chip, and haptics.

Three pins off the 34-pin header, plus GND and nPM_out2_3.3V for the boost's
logic side. More pins for the haptics and radar chip.

| Signal | Pad | Pin |
| --- | --- | --- |
| M0110 DATA | KSI1 | P0.01 |
| M0110 CLOCK | KSI2 | P0.02 |
| boost enable | KSO0 | P1.00 |

## Building

ZMK cannot target this SoC yet, so the build uses an experimental Zephyr 4.4
ZMK build in its own west workspace outside the repository.

```bash
./scripts/build-framework.sh --setup   # create the workspace, about 4 GB
./scripts/build-framework.sh           # build and sign
```

## Planned

A gesture layer on the side of the keyboard, using an Infineon BGT60TR13C
(60 GHz, 1 TX / 3 RX) to read thumb motion for click and a
velocity-controlled cursor.

Haptic feedback layer for wake, pairing, and notifications.

Large LiPo to make it last more than a week on a single charge.

## Branches

- `framework-cb` for the Framework Control Board build
- `nice-nano` for the nice!nano v2 build
- `m0110-hud` for the macOS companion app

## License

MIT
