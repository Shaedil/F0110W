# M0110 ZMK converter

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

With a ZMK/Zephyr environment (<https://zmk.dev/docs/development/setup>):

```bash
./scripts/build.sh          # west init, update, build
./scripts/build.sh --quick  # skip west init/update
```

With only Docker, in ZMK's build container:

```bash
./scripts/build-docker.sh   # fetches the workspace on first run, about 3 GB
```

## Flashing

Double-tap reset on the nice!nano and copy `build/zephyr/zmk.uf2` to the
mounted `NICENANO` drive.

## Clipboard

The keyboard carries text between computers: copy on one, switch Bluetooth
profile, and paste on the other. It holds the last text copied and hands it to
the next computer it is switched to. Images can be carried too, but only
between computers that both run a helper.

A keyboard cannot read a clipboard, so the computer that is copied from runs
a helper that sends each new clip over: the M0110HUD app on a Mac, and
`helper/m0110_clipboard.py` on Windows and Linux, both on the `m0110-hud`
branch. The computer that is pasted into does not need a helper:

- With a helper there, the clip goes onto its clipboard when the keyboard
  switches to it, and paste is an ordinary paste.
- Without one, the keyboard swallows the paste (V with Cmd or Ctrl) and types
  the clip out as plain text on a US layout, at a few dozen characters a
  second. Accented letters lose their accents, other scripts and emoji are
  dropped, and a line break or tab is typed as a space. Pressing any key
  stops it.

An image, or text too long for the keyboard, goes between two computers that
both run a helper. The keyboard carries a short message saying where the
content is, and the helper on the second computer fetches it from the first
over the local network, encrypted with a key that only ever travels through
the keyboard. If the two cannot reach each other, the content comes through
the keyboard instead, with an image scaled down to fit; that takes a good few
seconds. A computer without a helper cannot be handed an image at all, and a
paste there is left alone. `helper/PROTOCOL.md` on the `m0110-hud` branch has
the details.

The clip is kept only in RAM. It is wiped after two minutes, when anything
newer is copied on any computer the keyboard can see, and at reset. The
service needs an encrypted link, so only paired computers can read or write
it, and the helpers skip what password managers mark as concealed.

Limits: 16384 bytes of text, set by `CONFIG_ZMK_CLIPBOARD_MAX_LEN`; longer
text goes the way images do. A copy made with the mouse on a computer without
a helper is invisible to the keyboard, so for those two minutes a paste there
types the older clip. The keyboard cannot tell which of Cmd-V and Ctrl-V is
paste on a computer without a helper, so it takes both: with a clip in hand,
Ctrl-V in a terminal or Win-V types it too. The helper reaches the keyboard
over Bluetooth, so a computer connected by USB alone can be pasted into but
not copied from. `CONFIG_ZMK_CLIPBOARD=n` in `config/m0110.conf` builds
without any of it.

```bash
./tests/run.sh              # host tests, no Zephyr needed
```

## Profile report

ZMK stays connected to every paired computer and only sends keys to the active
profile, so a computer the keyboard has been switched away from still shows it
as connected and gets no keys. A small GATT service tells each connected
computer which profile is active and which one is its own, and notifies it on
every switch. The M0110HUD app uses it to say "Moved to ..." and
"Moved back". It needs an encrypted link, like the clipboard.
`config/src/profile_report.c` has the format, and
`CONFIG_ZMK_PROFILE_REPORT=n` leaves it out.

## License

MIT
