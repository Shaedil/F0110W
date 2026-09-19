# M0110 ZMK Converter, Framework control board

ZMK firmware that converts an Apple M0110/M0110A to USB and Bluetooth, running
on Framework's wireless keyboard control board (nRF54LM20A). For the nice!nano
v2 build, see the `nice-nano` branch.

## Hardware

- Framework wireless keyboard control board
- bq25185 boost: the board has no 5 V rail and the M0110 needs one
- Apple M0110 or M0110A

Three pins off the 34-pin header, plus GND and nPM_out2_3.3V for the boost's
logic side.

| Signal | Pad | Pin |
| --- | --- | --- |
| M0110 DATA | KSI1 | P0.01 |
| M0110 CLOCK | KSI2 | P0.02 |
| boost enable | KSO0 | P1.00 |

## Building

ZMK cannot target this SoC yet, so the build pins a Zephyr 4.4 tree in its own
west workspace outside the repository:

```bash
./scripts/build-framework.sh --setup   # create the workspace, about 4 GB
./scripts/build-framework.sh           # build and sign
```

## Flashing

There is no UF2 drive. Hold the pairing button through reset to enter MCUboot
serial recovery, then upload the signed image:

```bash
mcumgr --conntype serial --connstring dev=<port>,baud=115200 \
    image upload build-framework/zephyr/zmk.signed.bin
mcumgr --conntype serial --connstring dev=<port>,baud=115200 reset
```

## Tests

`bash tests/run.sh` replays 29 recorded wire sequences through the decoder.

## License

MIT
