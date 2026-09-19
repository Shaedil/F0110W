# M0110 ZMK Converter

A ZMK firmware for converting Apple M0110/M0110A keyboards to USB/Bluetooth
using a nice!nano v2 microcontroller.

## Prerequisites

This project requires a ZMK/Zephyr development environment. You must have
the following installed before building:

- [Zephyr SDK](https://docs.zephyrproject.org/latest/develop/getting_started/)
- [ZMK Firmware](https://zmk.dev/docs/development/setup)
- [West](https://docs.zephyrproject.org/latest/develop/west/) (Zephyr's meta-tool)

Follow the ZMK development setup guide to install all dependencies:
https://zmk.dev/docs/development/setup

## Hardware

- nice!nano v2 (or compatible nRF52840 board)
- BSS138-based bidirectional logic level shifter (3.3V <-> 5V)
- Apple M0110 or M0110A keyboard

### Wiring

```
M0110 Keyboard          Level Shifter           nice!nano v2
--------------          -------------           ------------
Clock -------------------- HV1 --- LV1 ------------ D3 (P0.20)
Data  -------------------- HV2 --- LV2 ------------ D2 (P0.17)
+5V   -------------------- HV  -------------------- (5V supply)
GND   -------------------- GND --- GND ------------ GND
                           LV  -------------------- 3.3V (VCC)
```

## Building

### Using the build script (recommended)

The build script initializes the workspace and builds the firmware:

```bash
# Full build (initializes workspace, updates dependencies, builds firmware)
./scripts/build.sh

# Quick rebuild (skips west init/update)
./scripts/build.sh --quick
```

### Manual build

Initialize the workspace and build manually:

```bash
west init -l config
west update
west build -s zmk/app -b nice_nano -- -DSHIELD=m0110 -DZMK_CONFIG="$(pwd)/config"
```

## Flashing

1. Double-tap the reset button on the nice!nano v2
2. Copy `build/zephyr/zmk.uf2` (or `zmk_working.uf2`) to the mounted `NICENANO` drive

## License

MIT
