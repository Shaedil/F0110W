# M0110HUD

A macOS menu-bar app for the M0110 converter. It draws the connect and battery
HUD macOS shows for Apple accessories but never for third-party Bluetooth
keyboards, and edits the keymap live over ZMK Studio.

The firmware is on the `nice-nano` and `framework-cb` branches.

## Requirements

macOS 13 or later, and the Swift toolchain (Command Line Tools is enough).

## Build

```sh
./build.sh
```

Writes `build/M0110HUD.app` and copies it over `/Applications/M0110HUD.app`.
The bundle is not optional: CoreBluetooth reads its usage description from
`Info.plist`, and macOS ties the permission grant to the code signature.

## Run

```sh
open build/M0110HUD.app          # first launch prompts for Bluetooth access
./install-agent.sh               # start at login, --uninstall to remove
```

Launch with `open` rather than from a shell, so macOS attributes the Bluetooth
permission to the app instead of your terminal.

Without hardware, `--test` shows a single HUD, `--preview` cycles the three HUD
states and `--snapshot <path>` renders a pane offscreen to a PNG.

To iterate on the HUD, run `tools/hud-dev.sh`. It opens a debug panel that
drives the real connect, disconnect and battery handlers by hand, and rebuilds
and relaunches on every save under `Sources/`, putting the last HUD back on
screen.

## Clipboard

With firmware that has the clipboard service, text copied on this Mac goes
with the keyboard when it switches Bluetooth profile: onto the other
computer's clipboard if a helper runs there, typed out by the keyboard if not.
A keyboard cannot read a clipboard itself, so each computer that is copied
from needs a helper, and this app is the Mac one. It also takes delivery of
clips copied elsewhere.

Text goes into the keyboard itself, up to the length it reports (16384 bytes
by default). An image, or longer text, goes between two computers that both
run a helper: the keyboard carries a short message, and the helper on the
second computer fetches the content from the first over the local network,
sealed with a key that only travels through the keyboard. macOS asks once for
permission to use the local network. If the two computers cannot reach each
other, the content comes through the keyboard instead, an image scaled down to
fit, and that takes a good few seconds. `helper/PROTOCOL.md` describes the
exchange.

When both text and an image are on the clipboard the text is carried, except
for an image copied in a browser, where the text is only its address. Items
marked concealed or transient, which is how password managers flag what they
copy, are never sent. Settings has the switch, and `--no-clipboard` keeps the
bridge from starting.

On Windows and Linux the helper is a script; `uv` fetches what it depends on
(`bleak`, `cryptography`, `pillow`). The keyboard has to be paired with that
computer already.

```sh
uv run helper/m0110_clipboard.py --verbose
```

Linux needs `wl-clipboard` on Wayland, or `xclip` or `xsel` on X11; `xsel`
carries text only.

```sh
swift test                  # the Mac side
uv run --with bleak --with cryptography --with pillow \
    python3 helper/test_m0110_clipboard.py
```

## Options

`--help` lists every flag with its default. The common ones are `--name`,
`--low`, `--rearm`, `--duration`, `--scale`, `--appearance`, `--transparency`,
`--headless`, `--no-clipboard`, `--studio-probe` and `--verbose`. Every setting also reads from
`UserDefaults` under `com.shaedil.m0110hud`, with flags taking precedence.

The HUD holds for seven seconds, long enough to still be there when a keyboard
that has been asleep all night finishes reconnecting. Its transparency follows
Accessibility > Display > Reduce transparency: on, and the blur is replaced by
an opaque background. macOS publishes that setting as a switch rather than a
level, so the in-between values are reachable only through `--transparency`.

## Known limits

- The percentage is a voltage proxy from ZMK's Battery Service reading, not a
  state of charge, and there is no charging indicator.
- Keymap editing rewrites a binding's keycode only, from HID page 0x07, and
  Studio has to be unlocked at the keyboard first.
- Studio answers on whichever endpoint the keyboard is currently output to,
  USB or Bluetooth, never both at once.

## License

MIT

The 3D case in `Resources/M0110.usdz` is
[Apple M0110 Keyboard](https://www.thingiverse.com/thing:4061711) by
StephenLulz, licensed CC BY. The keycaps, switches and converter boards were
modelled for this app; the source is `assets/M0110.blend`.
