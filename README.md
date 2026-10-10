# M0110HUD

A macOS menu-bar app for the M0110 converter. It draws the connect and battery
HUD macOS shows for Apple accessories but never for third-party Bluetooth
keyboards, and edits the keymap live over ZMK Studio. The HUD also builds for
Windows; see [Windows](#windows).

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

## Windows

The same HUD, in the corner by the tray, with a tray icon in place of the
menu bar item. It announces the same things at the same moments: what each
event shows is decided in `Announcer.swift`, which both builds share, along
with presence, settings and the Studio RPC client. The keymap editor and the
clipboard bridge are AppKit and SwiftUI and stay on the Mac; on Windows the
clipboard has its script, below.

Build it on Windows with the [Swift toolchain](https://www.swift.org/install/windows/):

```powershell
.\build.ps1             # build\M0110HUD\, the executable and the Swift runtime
.\build.ps1 -Install    # and copy it to %LOCALAPPDATA%\Programs\M0110HUD, and start it
```

Start at Login is in the tray menu, or `M0110HUD.exe --install`, which keeps
the other options given with it. The keyboard has to be paired with Windows.
`--ble-probe` says what Windows reports for it: found or not, connected, the
battery, the profile report. It is a GUI program, so pipe it to have
PowerShell wait for the output: `.\M0110HUD.exe --ble-probe | Out-Host`.

Profile names for "Moved to …" are kept on the keyboard, so the Mac and Windows
show the same ones, and are set in the window's Bluetooth pane. When this PC's
own profile has none, it names it "Windows 11 PC" (or 10); the keyboard numbers
twins. `%LOCALAPPDATA%\M0110HUD\settings.json` keeps a copy, as `profileNames`,
and names in it from before the keyboard kept them are offered to it once.
`--ble-probe` prints the names the keyboard has.

The HUD is drawn in software (`Windows/HUDRaster.swift`), so its look can be
worked on from a Mac: `tools/win-hud-preview.sh` draws every state to a PNG,
and `tools/win-typecheck.sh` type-checks the Windows Swift against the C
layer's header. The C layer itself (`Sources/CM0110Win`) needs Windows to
build; `.github/workflows/hud-windows.yml` builds it all on a Windows runner and
uploads the package and a `--snapshot` of every state.

Windows caches a paired keyboard's GATT services. If the firmware gained the
profile report after pairing, Windows will not show it until the keyboard is
removed and paired again; `--ble-probe` says so.

## When a HUD shows

- **Connected**: the keyboard appears, once its battery is read.
- **Disconnected**: the keyboard has been gone for 3 seconds
  (`--disconnect-grace`). Shorter drops happen several times a day and the
  link re-forms on its own, so they show nothing either way.
- **Moved to … / Moved back**: the keyboard switched Bluetooth profile away
  from this Mac, or back to it. ZMK keeps every profile's link up, so this
  needs firmware with the profile report (`config/src/profile_report.c`);
  older firmware never shows these. Profiles are named in Settings.
- **Battery**: each 10% step down, the low-battery alert, and an empty battery.

## Logs

Settings → Logs lists what the app heard from the keyboard and what it did
about it: Bluetooth links and profile reports, every HUD shown, the clipboard
and the Studio link. When a HUD did not show, the App lines say why, as in
"Profile 2 to Profile 1, neither is this computer (Profile 3); nothing shown".
Profiles are numbered from 1 there, as in Settings.

Every line also goes to `~/Library/Logs/M0110HUD/M0110HUD.log`, which keeps
what came before this launch; past 2 MB it moves to `M0110HUD.1.log`. The
debug panel and `--ui-dev` runs log only to the tab.

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
  Studio has to be unlocked at the keyboard first. The firmware locks it again
  after ten minutes without a request; the editor follows, and the same key
  unlocks it.
- Studio answers on whichever endpoint the keyboard is currently output to,
  USB or Bluetooth, never both at once.

## License

MIT

The 3D case in `Resources/M0110.usdz` is
[Apple M0110 Keyboard](https://www.thingiverse.com/thing:4061711) by
StephenLulz, licensed CC BY. The keycaps, switches and converter boards were
modelled for this app; the source is `assets/M0110.blend`.
