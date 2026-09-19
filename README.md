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

Without hardware, `--preview` cycles the three HUD states and `--snapshot
<path>` renders a pane offscreen to a PNG.

## Options

`--help` lists every flag with its default. The common ones are `--name`,
`--low`, `--rearm`, `--duration`, `--scale`, `--appearance`, `--headless`,
`--studio-probe` and `--verbose`. Every setting also reads from `UserDefaults`
under `com.shaedil.m0110hud`, with flags taking precedence.

## Known limits

- The percentage is a voltage proxy from ZMK's Battery Service reading, not a
  state of charge, and there is no charging indicator.
- Keymap editing rewrites a binding's keycode only, from HID page 0x07, and
  Studio has to be unlocked at the keyboard first.
- Studio answers on whichever endpoint the keyboard is currently output to,
  USB or Bluetooth, never both at once.

## License

MIT
