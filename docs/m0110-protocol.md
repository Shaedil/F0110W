# The Apple M0110 keyboard protocol

Reference notes for `config/drivers/kscan/`. This file is the specification the
driver implements against: every constant, timing and scancode in the driver
should be traceable to something written down here, and to a source cited at the
bottom.

The M0110 (1984), M0110A (1986) and the M0120 keypad all speak the same
two-wire protocol. The M0110A is an M0110 with the M0120's keypad and four
arrow keys built into one case, which is why the arrow keys behave so oddly:
they are reported as keypad keys.

## Electrical

Two open-collector signal lines, `CLOCK` and `DATA`, both idle high through
pull-ups. Either end may pull a line low; neither ever drives one high. The
keyboard is powered by +5 V from the host and shares its ground, so on a
battery-powered converter the 5 V rail has to be generated (see
`en-gpios` in the devicetree binding).

The keyboard always generates the clock, in both directions of transfer.
The host never clocks; it can only request a transfer and then follow the
keyboard's timing.

Bytes are transferred most-significant bit first, eight bits per transfer.

### Keyboard to host

The keyboard places a bit on `DATA`, pulls `CLOCK` low for roughly 160 µs,
releases it for roughly 180 µs, and repeats for all eight bits.

`DATA` is valid for the whole clock-low window. Apple's documentation describes
the host as reading on the rising edge; this driver instead samples inside the
low window, because sampling at the rising edge raced the keyboard's transition
to the next bit and intermittently latched the wrong value. A flipped bit 7
turns a release into a press, which strands a key down and lets the host's
auto-repeat spam it. The comments in `m0110_read_byte()` give the failure
analysis.

### Host to keyboard

The host requests a transfer by pulling `DATA` low while leaving `CLOCK` alone,
and holds it until the keyboard starts clocking, up to about 840 µs in normal
operation. The keyboard is entitled to take much longer if it is busy, so a
practical implementation waits on the order of a quarter second.

Once the keyboard begins clocking, the host asserts each bit while `CLOCK` is
low (about 180 µs) and holds it across the high period (about 220 µs). After
the last bit the host holds `DATA` for a further 80 µs or so, then releases
both lines to idle.

## Commands (host to keyboard)

| Value  | Name       | Keyboard's answer |
| ------ | ---------- | ----------------- |
| `0x10` | Inquiry    | The next key transition, blocking; `0x7B` if nothing happens within about 250 ms |
| `0x14` | Instant    | The next key transition if one is already pending, otherwise `0x7B` immediately |
| `0x16` | Model      | One model byte, see below |
| `0x36` | Test       | `0x7D` on pass, `0x77` on fail |

Inquiry is the normal idle command: it lets the host block on a semaphore
instead of polling, and its 250 ms answer doubles as a heartbeat. Instant is
for reading the remaining bytes of a multi-byte sequence, where the keyboard
already has them queued and a blocking read would be wrong.

## Reply bytes (keyboard to host)

A key transition is reported as a single byte:

```
bit 7    1 = key released (break), 0 = key pressed (make)
bits 6-1 key code
bit 0    always 1
```

Bit 0 being always 1 is a hard invariant of the encoding, not a checksum: every
key code the keyboard can emit is odd, and a break byte is its make byte with
bit 7 set, so it stays odd. Every protocol reply below is odd too. That makes
bit 0 a free one-bit frame check on every received byte, and the driver uses it
as one.

The key code occupies bits 6-1, so recovering it means masking and shifting
right by one. The result is a 7-bit value in the range `0x00`-`0x3F` for the
main key block.

Reserved reply values:

| Value  | Meaning |
| ------ | ------- |
| `0x7B` | No key transition pending |
| `0x79` | Prefix: the next byte is a keypad or arrow key |
| `0x71` | Shift pressed; also used as a prefix, see below |
| `0xF1` | Shift released; likewise |
| `0x7D` | Self-test passed |
| `0x77` | Self-test failed |

## Model bytes

| Value  | Keyboard |
| ------ | -------- |
| `0x03` | M0110 (GS536), and M0110F |
| `0x09` | M0110 (GS624) |
| `0x0B` | M0110A, M0110AJ |
| `0x11` | M0120 alone |
| `0x13` | M0120 with M0110 (G536) |
| `0x19` | M0120 with M0110 (G624) |
| `0x1B` | M0120 with M0110A (M923) |

Bit 0 is always 1; bits 3-1 identify the keyboard, bits 6-4 a second attached
device, and bit 7 is set when one is present.

## Multi-byte sequences

This is the awkward part of the protocol, and the only part of the driver with
real state.

Keypad and arrow keys are reported as two bytes: the prefix `0x79`, then
the key's own make or break byte.

The four "calc" keys on the keypad (`=`, `/`, `*`, `+`) share their key
codes with the four arrow keys, and are distinguished only by being wrapped in
a shift transition. Pressing keypad `/` sends `0x71`, `0x79`, then the same
byte the Up arrow would send; releasing it sends `0xF1`, `0x79`, and the Up
arrow's break byte.

| Key         | Press                | Release              |
| ----------- | -------------------- | -------------------- |
| Left arrow  | `0x79 0x0D`          | `0x79 0x8D`          |
| Right arrow | `0x79 0x05`          | `0x79 0x85`          |
| Up arrow    | `0x79 0x1B`          | `0x79 0x9B`          |
| Down arrow  | `0x79 0x11`          | `0x79 0x91`          |
| Keypad `+`  | `0x71 0x79 0x0D`     | `0xF1 0x79 0x8D`     |
| Keypad `*`  | `0x71 0x79 0x05`     | `0xF1 0x79 0x85`     |
| Keypad `/`  | `0x71 0x79 0x1B`     | `0xF1 0x79 0x9B`     |
| Keypad `=`  | `0x71 0x79 0x11`     | `0xF1 0x79 0x91`     |

The consequence is that a genuine Shift held while an arrow key is pressed is
indistinguishable from a calc key, because the keyboard emits the same three
bytes. No decoder can separate them; the protocol does not carry the
distinction. Every implementation has to pick a resolution, and the one this
driver picks is documented with the decoder.

A shift transition can also precede an ordinary key, and two shift transitions
can arrive back to back (both shift keys, or a shift release immediately
followed by a press). A decoder therefore cannot assume `0x71` is always a
prefix; sometimes it is just the Shift key.

## Scancode space

After stripping bit 7 and shifting right, main-block keys land in `0x00`-`0x3F`.
Keypad and arrow keys would collide with them, so the driver widens the space by
placing each group in its own block of a 14-row, 8-column matrix:

| Rows  | Scancodes     | Contents |
| ----- | ------------- | -------- |
| 0-7   | `0x00`-`0x3F` | Main key block, as sent |
| 8-11  | `0x40`-`0x5F` | Keypad and arrow keys |
| 12-13 | `0x60`-`0x6F` | Calc keys |

A scancode maps to a matrix position by splitting it at the row width: the row
is the scancode divided by eight, the column is the remainder. Eight columns is
the natural width because the main block is exactly 64 codes, and it leaves the
keypad and calc blocks on clean row boundaries. Those boundaries are where the
`0x40` and `0x60` block bases come from.

## Main-block scancodes (M0110A)

Values are the 7-bit code after decoding, in hex.

| Key | Code | Key | Code | Key | Code |
| --- | ---- | --- | ---- | --- | ---- |
| A | 00 | H | 04 | Q | 0C | 
| S | 01 | G | 05 | W | 0D |
| D | 02 | Z | 06 | E | 0E |
| F | 03 | X | 07 | R | 0F |
| C | 08 | T | 10 | Y | 11 |
| V | 09 | 1 | 12 | 2 | 13 |
| Non-US `\` | 0A | 3 | 14 | 4 | 15 |
| B | 0B | 6 | 16 | 5 | 17 |
| `=` | 18 | 9 | 19 | 7 | 1A |
| `-` | 1B | 8 | 1C | 0 | 1D |
| `]` | 1E | O | 1F | U | 20 |
| `[` | 21 | I | 22 | P | 23 |
| Return | 24 | L | 25 | J | 26 |
| `'` | 27 | K | 28 | `;` | 29 |
| `\` | 2A | `,` | 2B | `/` | 2C |
| N | 2D | M | 2E | `.` | 2F |
| Tab | 30 | Space | 31 | `` ` `` | 32 |
| Backspace | 33 | Enter (M0110) | 34 | Command | 37 |
| Shift | 38 | Caps Lock | 39 | Option | 3A |

Right Shift reports the same code as left Shift (`38`); the keyboard has no way
to tell them apart. Caps Lock is a physically locking switch: it sends a
make when it latches down and a break when it pops back up, with an arbitrary
amount of time in between. Hosts expect a momentary tap, so the driver
synthesises one on each transition.

## Keypad scancodes (M0110A)

Codes below are after decoding and after the block base has been added, so they
are what the matrix transform sees.

| Key | Code | Key | Code |
| --- | ---- | --- | ---- |
| Clear | 47 | Keypad 0 | 52 |
| Keypad 1 | 53 | Keypad 2 | 54 |
| Keypad 3 | 55 | Keypad 4 | 56 |
| Keypad 5 | 57 | Keypad 6 | 58 |
| Keypad 7 | 59 | Keypad 8 | 5B |
| Keypad 9 | 5C | Keypad `.` | 41 |
| Keypad Enter | 4C | Keypad `-` | 4E |
| Left arrow | 46 | Right arrow | 42 |
| Up arrow | 4D | Down arrow | 48 |
| Keypad `+` | 66 | Keypad `*` | 62 |
| Keypad `/` | 6D | Keypad `=` | 68 |

The arrow and calc pairs are the same underlying code in two different blocks:
Left/`+` are both `06`, Right/`*` are `02`, Up/`/` are `0D`, Down/`=` are `08`.

## Sources

- Apple Computer, *Technical Information for the Macintosh 128K and 512K*:
  keyboard protocol and timing on p. 20, raw scancode charts on p. 22.
- Apple Computer, *Technical Information for the Macintosh Plus*, p. 7.
- Mac Plus hardware notes, <http://www.mac.linux-m68k.org/devel/plushw.php>.
- kbdbabel connector and signaling diagrams,
  <http://www.kbdbabel.org/conn/kbd_connector_macplus.png> and
  <http://www.kbdbabel.org/signaling/kbd_signaling_mac.png>.
- Behaviour of the physical keyboard on the bench, for anything the documents
  leave ambiguous: the calc-key sequences and the locking Caps Lock.
