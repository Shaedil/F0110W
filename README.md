# M0110 ZMK Converter

ZMK firmware that converts an Apple M0110/M0110A to USB and Bluetooth on a
nice!nano v2. For the Framework control board build, see the `framework-cb`
branch.

## Hardware

- nice!nano v2, or another nRF52840 board
- BSS138 bidirectional level shifter, 3.3V to 5V
- LiPo charger with a 5 V boost
- Apple M0110 or M0110A

```
M0110 Keyboard          Level Shifter           nice!nano v2
Clock -------------------- HV1 --- LV1 ------------ D3 (P0.20)
Data  -------------------- HV2 --- LV2 ------------ D2 (P0.17)
+5V   -------------------- HV  -------------------- (5V supply)
GND   -------------------- GND --- GND ------------ GND
                           LV  -------------------- 3.3V (VCC)
```

## Building

Needs a ZMK/Zephyr environment: <https://zmk.dev/docs/development/setup>

```bash
./scripts/build.sh          # west init, update, build
./scripts/build.sh --quick  # skip west init/update
```

## Flashing

Double-tap reset on the nice!nano and copy `build/zephyr/zmk.uf2` to the
mounted `NICENANO` drive.

## License

MIT
