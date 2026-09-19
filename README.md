# M0110HUD

A top-right HUD for the M0110 converter, replicating the popup macOS shows for
Apple accessories but never shows for third-party Bluetooth keyboards.

Layout matches Apple's: device glyph on the left, name over status centered in
the middle, circular battery ring on the right with the level printed inside.
In the glyph slot an M0110 turns slowly in 3D; see The spinning board below.

| State | Look |
| --- | --- |
| Connected | turning board, name, `Connected`, green ring |
| Low Battery | normal board and number, `Low Battery`, red ring only |
| Disconnected | dimmed board, `Disconnected`, ring collapsed away (the level would be stale) |

## The missing popup

macOS already knows the keyboard is a keyboard: ZMK advertises GAP Appearance
`0x03C1` (HID/Keyboard) and `system_profiler SPBluetoothDataType` reports
`Minor Type: Keyboard`. But the connect popup is driven by `BluetoothUIService`
and restricted to recognized Apple products, and the Batteries widget resolves
its device glyph from product identity (VID/PID) rather than from the appearance
value. Neither has an extension point, so this app draws its own.

It uses only public API (CoreBluetooth for presence and battery) and does not
modify macOS or require any firmware change.

## Look

The window follows System 1.1's idiom, colourised: paper, flat 1px hairlines,
hard offset drop shadows, and inverted selection. It tracks the macOS theme,
because the whole palette is built from dynamic `NSColor`s, so paper and
hairlines invert in dark mode and the accent lifts to keep white text legible,
without any view observing `colorScheme`. No grey dialog faces and no bevels;
both belong to System 7 and later. Colour appears only as the selection accent
and in the icons. `ClassicTheme.swift` holds the palette, and `ClassicGlyph`
draws each sidebar icon pixel-by-pixel.

Type is Geneva. Chicago was the System font but Apple has never shipped it;
Geneva is the period-correct bitmap companion macOS still includes.

The app icon is the classic six-stripe Apple mark, drawn by
`tools/make-icon.swift` into `Resources/M0110.icns`. The mark is built once at
1024px and scaled down with smooth interpolation, so every size in the iconset
is crisp and the stripe edges stay consistent between them. It was previously
rasterised onto a 26px grid, alpha-thresholded and upscaled nearest-neighbour
for a deliberately blocky Mac OS 9 look, which does not survive being shown at
512px on a Retina display.

Regenerate it with:

```sh
swift tools/make-icon.swift /tmp/M0110.iconset \
  && iconutil -c icns /tmp/M0110.iconset -o Resources/M0110.icns \
  && ./build.sh
```

## The window

A floating sidebar, in the macOS 26 manner: a rounded slab inset from every
edge, laid over the content rather than partitioning the window, collapsible
with the toolbar button or ⌃⌘S.

- The blur is `NSVisualEffectView` in `.withinWindow` mode, not a SwiftUI
  material. SwiftUI's materials sample the window's backing, and over this
  theme's near-black gradient they resolve to a flat grey rather than blurring
  anything. `ImageRenderer` cannot rasterise an `NSViewRepresentable`, so
  offscreen snapshots fall back to a plain fill.
- The window controls sit inside the sidebar, as Finder does it. AppKit
  puts them at a fixed offset from the window's corner, so the panel has to
  reach nearly into that corner to enclose them, hence its small 8pt inset and
  a reserved band at the top of its content. The toggle therefore cannot
  keep one position: with the sidebar open it goes just past its trailing edge,
  and collapsed it takes the usual place beside the traffic lights, which are
  then over the content. Open, the toggle is *in* the sidebar, at the far end of
  the same row as the window controls.
- The root view sets `ignoresSafeArea(.container, edges: .top)`. Even with
  `fullSizeContentView`, SwiftUI insets its content by the title bar's safe
  area, which put the toggle a full title bar *below* the traffic lights it is
  meant to sit beside, and pushed everything else down with it.

The board is drawn as large as fits, up to 990pt. Legends are sized in
unit-hundredths, so one number sets both the keyboard's size and its type size.
The pane measures its own width rather than assuming one: at the window's
minimum size, or with the sidebar showing, there is not always room for the
preferred width, and a board wider than its container is clipped rather than
shrinking.

The window is a fixed size and cannot be resized by hand. Each dimension has two
values, and both follow what is on screen:

- Width follows the sidebar: 1340 open, 1110 collapsed. The difference is
  `RootView.sidebarSpan`, the sidebar plus both its margins.
- Height follows the keycode picker: 613 with just the board, 820 with a key
  selected. Each is where that panel's bottom edge lands, plus its margin.

So the window hands back exactly the space a hidden element was using, and the
board is identical through all four combinations rather than reflowing.
`WindowLayout` carries the two facts; `RootView` watches them rather than firing
from the toggle's action or the keycap's tap, so every route into these states
moves the window: the keyboard shortcut, the picker's Done button, switching
panes, a reload that empties the board. "Picker open" does not just mean "a key
is selected": it is only drawn on the Keys pane, and only once there is a board
to draw it under.

`.resizable` is off the style mask rather than only pinning min/max: bounds
alone still offer a resize cursor and a live zoom button, inviting a gesture
that does nothing. Min and max are pinned as well, as a backstop against a
frame set programmatically, such as a restored frame or a Stage Manager tile.
The resize is driven from `onChange(of: sidebarVisible)` rather than the
toggle's action, so the keyboard shortcut moves the window too, and the bounds
must be updated before `setFrame` or the resize is clamped straight back.

## Drawing the board

The keyboard in the Keys pane is vector art replicating a photograph of the real
M0110, not a generic key grid.

### Colour sources

- Case: Pantone 453, `#BFBB98`. Jerry Manock's "Apple Beige" spec for both
  the Apple II and the Macintosh. Used lifted and desaturated: 453 straight is
  distinctly olive, surviving boards read lighter and greyer, and the bezel has
  to stay clearly lighter than the caps.
- Keycaps: Pantone Cool Gray 2 U, `#C7C8BD`. This board wears XDA Oblique,
  an AEK-style keyset, and that is its colour. Near-neutral with a faint green
  cast against a frankly warm case: the caps are a different plastic, not a
  darker shade of the case. Matching the case's hue and only dropping the
  brightness makes them look like one moulding.
- Plate: black, the only hard edge the caps get now that the bezel is flat.

The original Apple caps were a warmer brown-grey; they went grey when the Mac
Plus moved to platinum in 1987. Cool Gray 2 is what is on this board.

### The shapes

- The bezel differs between the two boards. On the compact M0110 it is thin
  along the top and bottom and two and a half times as wide down each side; an
  even margin there comes out too square. The M0110A is an even frame.
- The bezel is flat: no gradient, no chamfer, no drop shadow. Shading made
  the case read as a rendered object floating over the page; the real thing is a
  large matte surface with no visible falloff, and a flat fill is what lets the
  black plate and the caps do the work.
- The M0110A has an ISO Return, the "big ass enter": a 2.25u × 2-row key
  with a 0.75u bite out of its top-left. It is one `DisplayKey` with a `cutout`,
  drawn as a single L-shaped cap. Two rectangles would draw two keycaps with a
  moulding line between them, which is the one thing an ISO Return is not. It is
  added to the layout table *after* the key beside it so it draws on top: its
  bite is transparent, and `contentShape` follows the L so the key underneath
  stays clickable.
- XDA is uniform rather than sculpted. Every row is the same height and shape,
  and the top is wide with only a shallow spherical dish. A deep taper would
  draw a Cherry cap; tilting rows toward the typist would draw the board's
  original Alps caps.
- The top face is a flat fill with a sheen over it, running left to right:
  lighter at the left edge, falling back to the cap's own colour at the right.
  It is white laid over the fill rather than a gradient between two named
  colours, so the spacebar and the selected cap, which have their own bases,
  get the same treatment without a second constant each to keep in step.
- A 1u top face is not square: it is about a fifth taller than it is wide. Only
  the top and bottom walls are chosen: they are fixed by the sculpt, so they set
  the face's height, and the side walls are then derived from that target
  aspect. Picking all three by eye left the face slightly wider than tall, which
  is the wrong way round for these caps.
- One constant sets every gap. `BoardCase.keyGap`, in unit-hundredths, and
  the plate's inset is exactly half of it: each cap already holds back half a
  gap inside its own cell, so half a gap of plate beyond the field makes the
  outer border measure the same as the gap between two caps. This used to be
  two values in *different units* (points between caps, units around the block),
  which cannot stay in step at any scale: the border came out about four times
  the inner gaps.
- The bottom row is centred, with the same inset at each end, and that
  inset is the Apple logo's cell. The spacebar's width is derived from that
  rather than measured: a square logo cell and a symmetric row are two
  constraints, every other key in the row is fixed, and the spacebar is the only
  thing left that can satisfy both.
- The bottom row's two end gaps are case rather than plate. They run out past
  the plate's edge so they open into the bezel instead of floating in the black
  as bright islands, and are held back half a gap from the neighbouring cap so
  the black beside them matches everywhere else.
- The Apple logo sits in a pocket cut into the bezel. The recess is what
  gives it contrast: moulded flush in the case's own beige, the logo is a shape
  with nothing behind it and all but disappears.

### The light is at the lower left

Everything bevelled follows one source, and it is not overhead:

- top faces run light at the bottom-left, shaded toward the top-right
- the visible wall is the *lower* one, lit along its face
- cap shadows fall up and to the right, onto the plate
- the logo pocket is lit *inverted*: its lower-left wall shades the floor and
  its upper-right wall catches the light, because the inside of a recess is the
  opposite of a proud edge

Getting the direction wrong is not a small error: it inverts every bevel in the
drawing at once, and the caps read as pressed rather than proud.

### Legends

`CapLegend` gives words (`Tab`, `Caps Lock`, `Shift`, `Return`, `Backspace`)
small in the top-left corner, shifted pairs (`!` over `1`) as a left-aligned
column, and letters centred. The spacebar is blank. They are derived from the
HID usage, not written out per key, so a cap rebound in the picker reprints
itself. The type is Helvetica, what the real caps are printed in, while the
app's own chrome stays on Geneva.

The spacebar is moulded a shade darker than the alphas. That is keyed off the
firmware *position*, not the binding: a spacebar rebound to something else is
still a spacebar.

## Reviewing the interface without hardware

`--snapshot` renders the window offscreen with `ImageRenderer`, using a fixture
that reproduces the shield's 79-key geometry. It needs no keyboard, no unlock
and no screen capture:

```sh
"build/M0110HUD.app/Contents/MacOS/M0110HUD" --snapshot /tmp/keys.png --snapshot-pane Keys
"build/M0110HUD.app/Contents/MacOS/M0110HUD" --snapshot /tmp/set.png  --snapshot-pane Settings
```

The spinning board has its own renderer, since it is neither a pane nor
something a screen capture can catch at a known angle:

```sh
"build/M0110HUD.app/Contents/MacOS/M0110HUD" --board-snapshot /tmp/spin.png
```

That writes a strip of six frames evenly spaced through one turn, drawn with
`SCNRenderer`, which needs no view, no window and no screen-recording grant.
(`SCNView.snapshot()` would: offscreen it returns empty frames.)

`ImageRenderer` gives a `ScrollView` no content size, so panes wrap their body
in `ClassicScroll`, which drops the scroll view while snapshotting. Pass
`--appearance light|dark` to render either theme; SwiftUI resolves dynamic
colours from `colorScheme`, not `NSApp.appearance`, so the snapshot sets the
scheme on the view itself.

## Build

```sh
./build.sh
```

Needs the Swift toolchain (Command Line Tools is enough). Output:
`build/M0110HUD.app`, which is then copied over `/Applications/M0110HUD.app`.

Every build installs. The app that actually gets looked at is the one in
`/Applications`, and a build that only wrote `build/` left it behind, which
reads as "the change did not land" rather than "you are running an old binary".

The `.app` bundle is not optional: CoreBluetooth's permission prompt reads
`NSBluetoothAlwaysUsageDescription` from `Info.plist`, and macOS remembers the
grant by code signature. A bare executable gets denied rather than prompted.

## Try it without hardware

```sh
"build/M0110HUD.app/Contents/MacOS/M0110HUD" --preview
```

Cycles through all three states, then quits. Combine with `--scale` to tune the
size without touching code:

```sh
"build/M0110HUD.app/Contents/MacOS/M0110HUD" --preview --scale 0.9
```

## Run it

```sh
open build/M0110HUD.app
```

First launch prompts for Bluetooth access. Launch via `open` rather than
running the binary from a shell, so macOS attributes the permission to the app
instead of to your terminal.

To watch what it's doing:

```sh
"build/M0110HUD.app/Contents/MacOS/M0110HUD" --verbose
```

```
[19:35:29] bluetooth ready; watching for "M0110"
[19:35:29] connected: M0110 [D1542B18-EFE7-E003-70EC-14037544584A]
[19:35:29] GATT link up
[19:35:29] battery 61%
[19:35:52] battery 64%
```

## Start at login

```sh
./install-agent.sh              # install and start
./install-agent.sh --uninstall  # remove
```

Installs a LaunchAgent with `--no-initial`, so logging in doesn't fire a HUD for
a keyboard that was already connected.

## Options

| Flag | Default | Meaning |
| --- | --- | --- |
| `--name <str>` | `M0110` | device name to *match*; the HUD displays whatever name the device reports |
| `--low <pct>` | `20` | low-battery trigger, fires once per descent |
| `--rearm <pct>` | `30` | level the battery must return to before re-alerting |
| `--duration <sec>` | `3.2` | how long the HUD stays visible |
| `--scale <factor>` | `1.0` | resize the whole HUD (clamped to 0.5 to 2.5) |
| `--inset-x <pt>` | `110` | inset of the HUD's right edge from the screen edge |
| `--inset-y <pt>` | `6` | gap below the menu bar |
| `--appearance <a>` | follow system | force `light` or `dark`; `auto` restores following |
| `--material <m>` | `toolTip` | vibrancy material (see below) |
| `--no-disconnect` | off | don't show a HUD when the keyboard disconnects |
| `--no-initial` | off | stay quiet if the keyboard was already connected at launch |
| `--headless` | off | HUD only: no window, no Dock icon (used by the LaunchAgent) |
| `--studio-probe` | none | check the ZMK Studio RPC link (USB, then Bluetooth) and exit |
| `--snapshot <path>` | none | render the UI offscreen to a PNG and exit |
| `--snapshot-pane <n>` | `Keys` | which pane to render |
| `--board-snapshot <path>` | none | render the spinning board as a six-frame strip and exit |
| `--preview` | none | show sample HUDs and quit; no Bluetooth needed |
| `--theme-cycle` | none | hold one HUD on screen and flip the app appearance beneath it |
| `-v`, `--verbose` | off | log state transitions |

Every setting also reads from `UserDefaults` (`defaults write
com.shaedil.m0110hud lowThreshold -int 15`), with CLI flags taking precedence.

## Presence and the panel

Presence is polled every 2s via
`CBCentralManager.retrieveConnectedPeripherals(withServices:)`, which reports
peripherals connected to *the system*; the keyboard's HID link belongs to
macOS, not to this app. On a new appearance the app opens its own GATT link
alongside that one, reads Battery Level (`0x2A19` on Battery Service `0x180F`),
and subscribes for updates. The matched peripheral's identifier is remembered in
`UserDefaults` so matching survives a `name` that comes back `nil`.

The HUD is a borderless non-activating `NSPanel` at `.statusBar` level with a
`.popover` visual-effect background. It ignores mouse events, joins all
Spaces, and never takes focus. Colors come from `labelColor` /
`secondaryLabelColor` and are resolved at draw time, so the HUD tracks light and
dark mode live: a theme change repaints a panel that is already on screen,
rather than only applying to the next one. `--theme-cycle` verifies this: it
holds one HUD up and overrides `NSApp.appearance` beneath it, which fires the
same propagation a System Settings change does. Only the battery arc uses a
fixed hue (green, red below the threshold), matching how macOS keeps status
colors constant across themes. Every dimension lives in `HUDMetrics` and derives
from one scale factor, calibrated against the menu bar's 13pt text.

macOS anchors its own accessory popup under that device's menu bar item rather
than the screen corner, which is why the default `--inset-x` is 110pt rather
than flush right.

Rounded corners come from the vibrancy view's `maskImage`, not a layer corner
radius: `layer.cornerRadius` clips the view's own drawing but leaves the
behind-window blur square, which shows as visible rectangular corners.

The material was picked by measurement. Screenshotting macOS's own accessory
popup and sampling its fill gave `rgb(56, 84, 89)` over this wallpaper; sweeping
every `NSVisualEffectView.Material` and sampling ours in the same spot put
`toolTip` / `sidebar` / `underWindowBackground` at `rgb(60, 80, 83)` and
`popover` at `rgb(79, 111, 115)`, so the default is `toolTip`. Capsule height
was matched the same way: 102px against Apple's 103px. Absolute values shift
with whatever is behind the window, so compare only same-position samples.

### The spinning board

The HUD's product glyph is a 3D M0110, turning once every 7.5 seconds.

It is not an imported model. `BoardScene` builds a chamfered `SCNBox` at the
real board's proportions, read from `BoardHull`, which derives them from the
same `M0110Layout` table the Keys pane draws, and lays `BoardArtView`'s vector
art on its top face, case cream on the other five. So the board that spins here
and the board you edit keys on are one drawing; neither can be restyled without
the other following.

The framing was settled by rendering:

- The camera sits at 35°, not overhead. A rotating footprint projects to
  `depth × sin(elevation)`, so the steeper, more photo-like camera is the one
  whose corners fall out of a short frame.
- It is framed for the widest point of the turn. A board seen at 30°
  projects *wider* than the same board seen square on, so framing it flush
  head-on clips it for most of every rotation.
- The slot is squarer than the board: 1.45:1 against the board's own 2.6:1,
  for the same reason.

The art is rasterised once per appearance and cached; `AppDelegate` warms it at
launch, because otherwise that render (~20 ms) lands on the main thread at the
exact moment the keyboard connects.

Width is content-fitted, so a short name yields a compact capsule the way
Apple's does; `minWidth` only sets a floor.

## Keymap editing

The window's Keys pane edits the live keymap over ZMK Studio's RPC, which
runs on a USB CDC ACM port (Bluetooth is not a Studio transport on this build).
`Studio/` implements the protocol directly:

- `Protobuf.swift`: a minimal wire-format codec. Hand-rolled on purpose:
  SwiftProtobuf would add a `protoc-gen-swift` toolchain step and a
  network-fetched SwiftPM dependency for about a dozen message shapes.
- `Transport.swift`: the SOF/ESC/EOF framing from
  `zmk/app/src/studio/msg_framing.h`, plus a blocking serial port.
- `StudioClient.swift`: the `zmk.studio.Request/Response` envelope and the
  core/keymap/behaviors calls.

Verify the link without any UI:

```sh
"build/M0110HUD.app/Contents/MacOS/M0110HUD" --studio-probe --verbose
```

Bindings are labelled from behaviour metadata rather than guessed. ZMK packs a
parameter as `(usage_page << 16) | usage_id`, so a `&kp` slot decodes to a
keycode, while `&mo`, `&bt`, `&out` and `&trans` do not. The app fetches every
behaviour's parameter description and only offers the keycode picker where
param1 really is a HID usage.

The layout is a superset, so the M0110 view is re-laid rather than filtered.
The shield's `m0110a_layout` covers every variant, so the firmware reports 79
positions with ISO proportions: a narrow 1.25u Return and a non-US backslash.
A US board has neither. `M0110Layout.ansi` maps the same firmware positions to
true ANSI geometry, which means deliberate departures from what the firmware
reports: position 53 (non-US backslash) is dropped, position 47 (Return) widens
to 2.25u, and position 72 (backslash) moves from the bottom row up to the end of
the tab row. Selecting M0110A draws the firmware's own geometry unchanged.

## Known limits

- No charging indicator, and the percentage is not a state-of-charge
  reading. ZMK reports battery over the standard Battery Service, a single
  0-100 byte with no charging flag, and has no charging detection at all; the
  shield doesn't even wire the bq25185's `/CHG` pin. Worse, the number is a
  voltage proxy: `zmk,battery-nrf-vddh` samples the nRF52840's `VDDHDIV5`
  channel and `battery_nrf_vddh.c` maps it through a linear curve
  (`pct = mv * 2 / 15 - 459`, i.e. 3450 mV = 0%, 4200 mV = 100%). That slope is
  7.5 mV per percentage point, so any rail movement (the M0110's 5V boost
  load switching on and off via `en-gpios`, charger offset, cell recovery)
  shows up as several percent. Observed live: 61% to 64% in 23 seconds, which on
  a 10 Ah cell at 1 A would be 0.06% of actual capacity. Treat the number as a
  rough voltage indicator, not a fuel gauge. A real fix is a coulomb-counting
  gauge IC (MAX17048 or similar), not host-side code.
- Battery updates are not instant. ZMK samples every
  `CONFIG_ZMK_BATTERY_REPORT_INTERVAL` seconds (default 60) and only pushes a
  BAS notification when the integer percentage changes.
- Only the keycode changes, not the behaviour. Rebinding preserves the
  binding's behaviour and rewrites param1, so a `&kp` moves to another keycode.
  Turning a `&kp` into a `&mo`, or editing `&bt`/`&out` parameters, is not
  implemented.
- Consumer-page keycodes are missing from the picker. The keymap uses
  `&kp C_VOL_UP` and friends on layer 1; those live on usage page 0x0C, and the
  picker currently offers page 0x07 only. They display as a raw hex parameter.
- Studio runs over Bluetooth as well as USB. `StudioTransport` is the seam:
  `SerialTransport` wraps a CDC ACM port, `BLETransport` wraps the firmware's
  GATT service (`00000000-0196-6107-c967-c5cfb1c2482a`, one write/indicate
  characteristic). Framing and protobuf are identical on both, so only the byte
  channel differs.

  Only one is ever live. The firmware selects its RPC transport from the
  endpoint the keyboard is *outputting* to (`refresh_selected_transport` in
  `zmk/app/src/studio/rpc.c`), and `write_rpc_req` drops every write while the
  GATT transport is not the selected one. So a board plugged into USB cannot
  answer over Bluetooth, and vice versa; the keymap's Fn layer has
  `&out OUT_BLE` for switching. Discovery tries serial first purely on cost:
  probing a port is instant, while the Bluetooth route has to connect and
  subscribe before it can answer.

  The characteristic is `PERM_READ_ENCRYPT`/`PERM_WRITE_ENCRYPT`, so the link
  must be bonded, which it already is for HID. Responses arrive as indications
  capped at 27 bytes by the firmware, so one reply spans many of them and the
  shared `StudioFraming.Decoder` reassembles it.

- Studio refuses reads as well as writes while locked. It replies on the
  `meta` subsystem with `UNLOCK_REQUIRED`, so the keymap cannot even be listed
  until the `&studio_unlock` key is pressed. The lock re-arms after
  `ZMK_STUDIO_LOCK_IDLE_TIMEOUT_SEC` (600 by default) and on disconnect.

  Because of that, unlocking is what triggers the first real load, and the
  unlock happens *at the keyboard*, where the app cannot see it. So while
  locked, `KeyboardController` polls `lockState()` every 1.5s and fetches the
  layout, keymap and behaviour table the moment it opens, then stops polling.
  Noticing the state change without going back for the data is the bug this
  replaced: a board correctly labelled "unlocked" and completely blank.
  (Studio does send a notification, but `StudioClient` discards unsolicited
  frames rather than running a reader thread.)

  The re-lock is not polled for, only the unlock. An idle re-arm is noticed
  when the next request fails, which puts the app back into the polling state.
- `save_changes` is implemented but untested on hardware. Reads, layout,
  behaviour metadata and lock state are all verified against the real keyboard;
  writing a binding and committing it to flash has not been exercised.
- The connect HUD may briefly show a stale percentage. It appears
  immediately and is updated in place when the fresh BAS read lands, typically
  under a second later.
