#!/usr/bin/env python3
"""Tests for m0110_clipboard.py, and a few modes for trying it against M0110HUD.

    uv run --with bleak --with cryptography --with pillow python3 helper/test_m0110_clipboard.py

Runs on any system: the clipboards are stand-ins, and so is the keyboard,
which follows the firmware's rules as far as a helper can see them. Two
helpers are joined through it and a copy is carried from one to the other
each of the ways PROTOCOL.md describes.

To try the stream against the other implementation, one side of it at a time:

    ... test_m0110_clipboard.py interop-serve <kind> <file>     prints PORT IDHEX KEYHEX
    ... test_m0110_clipboard.py interop-get <host> <port> <idhex> <keyhex>
    ... test_m0110_clipboard.py interop-accept <idhex> <keyhex>   prints PORT, then what was PUT
    ... test_m0110_clipboard.py interop-put <host> <port> <idhex> <keyhex> <file>
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import io
import json
import os
import random
import sys
import time
import types
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import m0110_clipboard as helper
from m0110_clipboard import (
    ACK,
    BEGIN,
    BYE,
    CANCEL,
    CLEAR,
    DATA,
    END,
    GONE,
    HELLO,
    HOLD,
    HOLD_OFF,
    HOLD_SOON,
    KIND_JPEG,
    KIND_PNG,
    KIND_TEXT,
    OPAQUE,
    RELAY,
    RESULT,
    STATUS,
    WANT,
    Assembler,
    Bridge,
    Clip,
    Endpoint,
    LinuxClipboard,
    Offer,
    Offering,
    TransferError,
)

TICKET = bytes(range(8))
KEY = bytes(range(0x10, 0x30))


# ---- Stand-ins ----


class FakeClipboard:
    """A clipboard in memory, with the change counter Windows has, and its quirks on request."""

    def __init__(self) -> None:
        self.clip = Clip(None)
        self.count = 0
        # Who put it there, as Windows would say; None for a system that cannot.
        self.owner: object = None
        # Reads that find another program holding the clipboard open.
        self.held = 0
        # Reading has a promised format rendered, which moves the counter.
        self.renders = False
        # How long a write takes.
        self.slow = 0.0
        self.reads = 0

    def copy(self, clip: Clip, owner: object = None) -> None:
        """The user copies something on this computer."""
        self.clip = clip
        self.count += 1
        if owner is not None:
            self.owner = owner

    def read(self) -> Clip | None:
        if self.held:
            self.held -= 1
            return None
        self.reads += 1
        if self.renders:
            self.count += 1
        clip = self.clip
        return Clip(clip.text, clip.private, clip.image, clip.form, owner=self.owner, after=self.count)

    def marker(self, fresh: bool = False) -> object:
        return self.count

    def write(self, text: str) -> bool:
        time.sleep(self.slow)
        self.copy(Clip(text), owner=0 if self.owner is not None else None)
        return True

    def write_image(self, png: bytes) -> bool:
        time.sleep(self.slow)
        self.copy(Clip(None, image=png, form="png"), owner=0 if self.owner is not None else None)
        return True


class FakeClient:
    """What bleak gives a helper: a way to write to the keyboard and to hear from it."""

    def __init__(self, keyboard: FakeKeyboard, profile: int) -> None:
        self.keyboard = keyboard
        self.profile = profile
        self.is_connected = True
        self.callback = None
        self.services = self
        # The session behind the characteristics has gone, as on Windows
        # just after the link drops.
        self.broken = False
        # How long a write takes to go out.
        self.lag = 0.0

    def get_characteristic(self, _uuid):
        if self.broken:
            raise AssertionError("no session")
        return types.SimpleNamespace(max_write_without_response_size=self.keyboard.cap)

    async def start_notify(self, _uuid, callback) -> None:
        self.callback = callback

    async def write_gatt_char(self, _uuid, frame, response: bool = False) -> None:
        if not self.is_connected:
            from bleak.exc import BleakError

            raise BleakError("Not connected")
        self.keyboard.write(self.profile, bytes(frame))
        await asyncio.sleep(self.lag)


class FakeKeyboard:
    """The firmware's rules, as far as a helper can see them.

    It holds one clip and where it came from, hands it frame by frame to the
    helper on the selected profile, passes RELAY datagrams between the two
    ends of the clip, keeps track of who has asked for pastes to be held, and
    takes nothing longer than the link carries. See config/clipboard/clipboard.c.
    """

    def __init__(
        self, version: int = 2, max_len: int = 16384, max_opaque: int = 61440, cap: int = 62, pace: float = 0.0
    ) -> None:
        self.version = version
        self.max_len = max_len
        self.max_opaque = max_opaque
        self.cap = cap
        # Time between the frames of a delivery.
        self.pace = pace
        self.clients: dict[int, FakeClient] = {}
        # Profile to the version its helper said HELLO with.
        self.helpers: dict[int, int] = {}
        self.selected = 0

        self.clip: dict | None = None
        self.origin = 0
        self.rx: dict | None = None
        self.generation = 0
        # The profile that last sent word to the computer the clip came from.
        self.requester: int | None = None
        self.relay_slot: dict | None = None
        # Who is being held for: profile, whether soon, and until when.
        self.hold: tuple[int, bool, float] | None = None
        self.delivery: tuple[asyncio.Task, int, int] | None = None

        # Everything the helpers wrote and when, for the tests to look through.
        self.written: list[tuple[int, bytes]] = []
        self.times: list[float] = []
        # HOLD frames that were acted on.
        self.honoured: list[tuple[int, int]] = []
        # Writes longer than the link takes: a helper's bug, wherever it is.
        self.oversize: list[bytes] = []
        self.restarts = 0

    def attach(self, profile: int) -> FakeClient:
        self.clients[profile] = FakeClient(self, profile)
        return self.clients[profile]

    def frames(self, profile: int, kind: int) -> list[bytes]:
        return [frame for sender, frame in self.written if sender == profile and frame[0] == kind]

    def when(self, profile: int, kind: int) -> list[float]:
        return [
            at for (sender, frame), at in zip(self.written, self.times) if sender == profile and frame[0] == kind
        ]

    def notify(self, profile: int, frame: bytes) -> None:
        client = self.clients[profile]
        if client.callback and client.is_connected:
            asyncio.get_running_loop().call_soon(client.callback, None, bytearray(frame))

    def wipe(self) -> None:
        self.clip = None
        self.rx = None
        self.generation += 1
        self.requester = None
        self.hold = None

    def select(self, profile: int) -> None:
        self.selected = profile
        self.evaluate()

    def understands(self, profile: int, opaque: bool) -> bool:
        return self.helpers.get(profile, 0) >= (2 if opaque else 1)

    def held(self, profile: int) -> bool:
        """Whether pastes on `profile` are being kept back right now."""
        return bool(self.hold and self.hold[0] == profile and asyncio.get_running_loop().time() < self.hold[2])

    def helper_gone(self, profile: int) -> None:
        self.helpers.pop(profile, None)
        if self.hold and self.hold[0] == profile:
            self.hold = None
        if self.relay_slot and self.relay_slot["from"] == profile:
            self.relay_slot = None

    def evaluate(self) -> None:
        """Starts handing the clip to the helper on the selected profile, if it is owed it."""
        clip, to = self.clip, self.selected
        if not clip or to == self.origin or not self.understands(to, clip["opaque"]) or to in clip["delivered"]:
            return
        if self.delivery and self.delivery[1:] == (self.generation, to):
            return
        if self.delivery:
            self.delivery[0].cancel()
        task = asyncio.ensure_future(self.deliver(self.generation, to, clip))
        self.delivery = (task, self.generation, to)

    async def deliver(self, generation: int, to: int, clip: dict) -> None:
        for frame in helper.transfer(clip["bytes"], OPAQUE if clip["opaque"] else 0, self.cap):
            # Abandoned without a word if it is no longer wanted.
            if generation != self.generation or self.selected != to or to not in self.helpers:
                return
            self.notify(to, frame)
            await asyncio.sleep(self.pace)

    def flush_relay(self) -> None:
        slot, self.relay_slot = self.relay_slot, None
        if slot is None:
            return
        sender, to, frame = slot["from"], slot["to"], slot["frame"]
        if to is None and (self.clip or self.rx) and sender == self.origin:
            # An answer, wherever the keyboard has been switched to since.
            if self.requester is not None:
                to = self.requester
            elif self.selected != sender:
                to = self.selected
        if to is not None and self.understands(to, True) and len(frame) <= self.cap:
            self.notify(to, frame)
        else:
            self.notify(sender, bytes([RESULT, 3, 0, 0, 0, 0]))

    def write(self, profile: int, frame: bytes) -> None:
        now = asyncio.get_running_loop().time()
        self.written.append((profile, frame))
        self.times.append(now)
        if len(frame) > self.cap:
            self.oversize.append(frame)
            return
        kind = frame[0]

        if kind == HELLO:
            self.helper_gone(profile)
            self.helpers[profile] = frame[1] if len(frame) >= 2 else 1
            if self.version >= 2:
                status = bytes([STATUS, 2]) + self.max_len.to_bytes(2, "little") + self.max_opaque.to_bytes(2, "little")
            else:
                status = bytes([STATUS, 1]) + self.max_len.to_bytes(2, "little")
            self.notify(profile, status)
            # A helper that has just started has not seen what its
            # predecessor was sent, so a clip it has yet to acknowledge is
            # offered again from the start.
            owed = self.clip and profile not in self.clip["delivered"]
            if owed and self.delivery and self.delivery[1:] == (self.generation, profile):
                self.delivery[0].cancel()
                self.delivery = None
                self.restarts += 1
        elif kind == BYE:
            self.helper_gone(profile)
        elif kind == BEGIN and len(frame) >= 8:
            # A clip that replaces one from the same computer may be its
            # answer to whoever asked after the last.
            requester = self.requester if profile == self.origin else None
            self.wipe()
            self.origin = profile
            self.requester = requester
            length = int.from_bytes(frame[2:4], "little")
            crc = int.from_bytes(frame[4:8], "little")
            opaque = bool(frame[1] & OPAQUE) and self.version >= 2
            if length > (self.max_opaque if opaque else self.max_len):
                self.notify(profile, bytes([RESULT, 1]) + crc.to_bytes(4, "little"))
            elif length:
                self.rx = {"opaque": opaque, "length": length, "crc": crc, "data": bytearray(), "bad": False}
        elif kind == DATA and self.rx and profile == self.origin:
            offset = int.from_bytes(frame[1:3], "little")
            if offset != len(self.rx["data"]) or len(frame) - 3 > self.rx["length"] - offset:
                self.rx["bad"] = True
            else:
                self.rx["data"] += frame[3:]
        elif kind == END and self.rx and profile == self.origin:
            rx, self.rx = self.rx, None
            data = bytes(rx["data"])
            good = not rx["bad"] and len(data) == rx["length"] and zlib.crc32(data) == rx["crc"]
            self.notify(profile, bytes([RESULT, 0 if good else 2]) + rx["crc"].to_bytes(4, "little"))
            if good:
                self.clip = {"bytes": data, "crc": rx["crc"], "opaque": rx["opaque"], "delivered": set()}
                self.generation += 1
        elif kind == CLEAR:
            self.wipe()
        elif kind == ACK and len(frame) >= 5:
            if self.clip and int.from_bytes(frame[1:5], "little") == self.clip["crc"]:
                self.clip["delivered"].add(profile)
            if self.hold and self.hold[0] == profile:
                self.hold = None
        elif kind == HOLD and self.version >= 2:
            flags = frame[1] if len(frame) >= 2 else 0
            current = self.clip or self.rx
            if flags & HOLD_OFF:
                if self.hold and self.hold[0] == profile:
                    self.hold = None
            elif current and current["opaque"] and profile != self.origin and self.understands(profile, True):
                # Only for an opaque clip from another computer.
                self.hold = (profile, bool(flags & HOLD_SOON), now + 4 * helper.HOLD_SECONDS)
                self.honoured.append((profile, flags))
        elif kind == RELAY and self.version >= 2 and len(frame) <= helper.RELAY_MAX:
            # Only the latest is kept. Word for the computer the clip came
            # from is addressed now: the sender's next frame may begin a
            # clip of its own.
            self.relay_slot = {"from": profile, "to": None, "frame": frame}
            if (self.clip or self.rx) and profile != self.origin:
                self.relay_slot["to"] = self.origin
                self.requester = profile
            asyncio.get_running_loop().call_soon(self.flush_relay)

        self.evaluate()


async def blocked(_address: str, _port: int):
    raise OSError("no route to host")


async def hangs(_address: str, _port: int):
    await asyncio.sleep(3600)


class World:
    """A keyboard, and a helper on each of two computers: profile 0 and profile 1."""

    def __init__(self, keyboard: FakeKeyboard | None = None, dials=(None, None)) -> None:
        self.keyboard = keyboard or FakeKeyboard()
        self.dials = dials
        self.bridges: list[Bridge] = []
        self.boards: list[FakeClipboard] = []
        self.tasks: list[asyncio.Task] = []

    async def __aenter__(self) -> World:
        for profile in (0, 1):
            endpoint = Endpoint(dial=self.dials[profile], addresses=lambda: ["127.0.0.1"])
            await endpoint.start()
            board = FakeClipboard()
            bridge = Bridge(self.keyboard.attach(profile), board, "M0110", endpoint)
            self.boards.append(board)
            self.bridges.append(bridge)
            self.tasks.append(asyncio.ensure_future(bridge.run()))
        await until(lambda: len(self.keyboard.frames(0, HELLO)) and len(self.keyboard.frames(1, HELLO)))
        await until(lambda: all(bridge.seen is not None for bridge in self.bridges))
        await asyncio.sleep(0.05)
        return self

    async def __aexit__(self, failed, *_exc) -> None:
        for task in self.tasks:
            task.cancel()
        await asyncio.wait(self.tasks)
        for bridge in self.bridges:
            await bridge.close()
            await bridge.endpoint.stop()
        if failed:
            return
        for task in self.tasks:
            if not task.cancelled() and task.exception():
                raise task.exception()
        assert not self.keyboard.oversize, "a frame longer than the link takes was written"


async def until(condition, timeout: float = 5.0) -> None:
    deadline = asyncio.get_running_loop().time() + timeout
    while not condition():
        assert asyncio.get_running_loop().time() < deadline, "timed out waiting"
        await asyncio.sleep(0.01)


def picture(width: int, height: int, noisy: bool = False) -> bytes:
    """A PNG: a gradient, or with `noisy` something that does not compress."""
    from PIL import Image

    image = Image.new("RGB", (width, height))
    source = random.Random(7)
    if noisy:
        image.putdata([(source.randrange(256), source.randrange(256), source.randrange(256)) for _ in range(width * height)])
    else:
        image.putdata([(x * 255 // width, y * 255 // height, 128) for y in range(height) for x in range(width)])
    out = io.BytesIO()
    image.save(out, "PNG")
    return out.getvalue()


def holds(keyboard: FakeKeyboard, profile: int) -> list[int]:
    return [frame[1] for frame in keyboard.frames(profile, HOLD)]


def acks(keyboard: FakeKeyboard, profile: int) -> list[int]:
    return [int.from_bytes(frame[1:5], "little") for frame in keyboard.frames(profile, ACK)]


def opaque_begins(keyboard: FakeKeyboard, profile: int) -> list[bytes]:
    return [frame for frame in keyboard.frames(profile, BEGIN) if frame[1] & OPAQUE]


def order(keyboard: FakeKeyboard, profile: int) -> list[bytes]:
    return [frame for sender, frame in keyboard.written if sender == profile]


def after_last(keyboard: FakeKeyboard, profile: int, kind: int) -> list[bytes]:
    """What `profile` wrote after its last frame of `kind`."""
    own = order(keyboard, profile)
    last = max(index for index, frame in enumerate(own) if frame[0] == kind)
    return own[last + 1 :]


def longest_wait_for_a_hold(keyboard: FakeKeyboard, profile: int) -> float:
    """The longest the keyboard went without a HOLD between the first one and the ACK that ended it."""
    marks = keyboard.when(profile, HOLD) + keyboard.when(profile, ACK)[:1]
    return max(later - earlier for earlier, later in zip(marks, marks[1:]))


# ---- The format ----


def test_vectors() -> None:
    offer = Offer(KIND_PNG, TICKET, KEY, 51234, ["192.168.1.20", "fd00::1234"])
    wanted = (
        "01020001020304050607101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f"
        "22c80204c0a8011406fd000000000000000000000000001234"
    )
    assert offer.encode().hex() == wanted
    parsed = Offer.parse(bytes.fromhex(wanted))
    assert (parsed.kind, parsed.ticket, parsed.key, parsed.port) == (KIND_PNG, TICKET, KEY, 51234)
    assert parsed.addresses == ["192.168.1.20", "fd00::1234"]

    want = helper.encode_want(TICKET, 40000, ["10.0.0.7"], 63)
    assert want.hex() == "010001020304050607409c01040a000007"
    assert helper.parse_want(want) == (TICKET, 40000, ["10.0.0.7"])

    # Two records, which takes a record size smaller than the content.
    whole = helper.RECORD_MAX
    helper.RECORD_MAX = 7
    try:
        records = list(helper.seal(KEY, TICKET, b"hello, world"))
    finally:
        helper.RECORD_MAX = whole
    assert [record.hex() for record in records] == [
        "0017000000607f787e815ec174019f43e6bffb11c2ecfbffa81efddf",
        "0115000000100a35e63e77753531f04ac52596a7a96c6b099f1d",
    ]
    assert [record.hex() for record in helper.seal(KEY, TICKET, b"")] == [
        "0110000000570bfcee544eff0e3cf8e15b02478f22"
    ]
    assert helper.TAKEN == b"\x01" and (WANT, GONE, CANCEL) == (1, 2, 3)


def test_messages() -> None:
    six = ["10.0.0.%d" % n for n in range(1, 9)]
    # Never more than six, and never more than fit.
    assert len(Offer.parse(Offer(KIND_TEXT, TICKET, KEY, 1, six).encode()).addresses) == 6
    assert Offer.parse(Offer(KIND_TEXT, TICKET, KEY, 1, six).encode(45 + 11)).addresses == six[:2]
    assert Offer(KIND_TEXT, TICKET, KEY, 1, six).encode(44) is None
    assert Offer.parse(Offer(KIND_TEXT, TICKET, KEY, 1, []).encode()).addresses == []
    # The largest OFFER there can be fits the least a keyboard may hold.
    widest = Offer(KIND_PNG, TICKET, KEY, 1, ["fd00::%d" % n for n in range(1, 8)]).encode()
    assert len(widest) == 45 + 6 * 17 <= helper.MIN_OPAQUE

    # A WANT cut to what a 20-byte frame leaves room for, and one with nothing.
    mixed = ["192.168.1.2", "192.168.1.3", "fd00::1"]
    assert helper.parse_want(helper.encode_want(TICKET, 9, mixed, 19))[2] == ["192.168.1.2"]
    assert helper.parse_want(helper.encode_want(TICKET, 9, mixed, 63))[2] == mixed
    bare = helper.encode_want(TICKET, 9, [], 19)
    assert len(bare) == 12 and helper.parse_want(bare) == (TICKET, 9, [])

    # Truncated, mistyped and overrunning messages are refused.
    good = Offer(KIND_PNG, TICKET, KEY, 1, ["10.0.0.1"]).encode()
    assert Offer.parse(good[:-1]) is None
    assert Offer.parse(good[:44]) is None
    assert Offer.parse(bytes([9]) + good[1:]) is None
    assert Offer.parse(good[:44] + bytes([1, 5, 1, 2, 3, 4])) is None
    assert helper.parse_want(helper.encode_want(TICKET, 9, mixed, 63)[:-1]) is None
    assert helper.parse_inline(bytes([helper.INLINE, KIND_TEXT]) + TICKET[:7]) is None

    inline = helper.encode_inline(KIND_TEXT, TICKET, b"words", 100)
    assert helper.parse_inline(inline) == (KIND_TEXT, TICKET, b"words")
    assert helper.encode_inline(KIND_TEXT, TICKET, b"x" * 91, 100) is None
    assert len(helper.encode_inline(KIND_TEXT, TICKET, b"x" * 90, 100)) == 100

    # Half a surrogate pair, which a Windows clipboard can hold, has no UTF-8.
    assert helper.text_bytes("a\ud83db\r\nc") == b"a?b\nc"
    assert Clip("a\ud83db").fingerprint() == Clip("a?b").fingerprint()
    assert Clip("x").fingerprint() != Clip(None, image=b"x", form="png").fingerprint()


def test_assembler() -> None:
    payload = bytes(n * 7 & 0xFF for n in range(65535))
    assembler = Assembler()
    for frame in helper.transfer(payload, OPAQUE, 62):
        assert len(frame) <= 62
        {BEGIN: assembler.begin, DATA: assembler.feed}.get(frame[0], lambda _frame: None)(frame)
    assert assembler.end() == (payload, zlib.crc32(payload), OPAQUE)

    frames = helper.transfer(b"0123456789", 0, 8)
    assembler.begin(frames[0])
    assembler.feed(frames[2])
    assert assembler.end() is None


def test_images() -> None:
    from PIL import Image

    big = picture(700, 500, noisy=True)
    assert len(big) > 40000
    inline = helper.encode_inline(KIND_PNG, TICKET, big, 40000)
    assert inline is not None and len(inline) <= 40000
    kind, ticket, content = helper.parse_inline(inline)
    assert kind == KIND_JPEG and ticket == TICKET
    shrunk = Image.open(io.BytesIO(content))
    assert shrunk.format == "JPEG" and shrunk.size[0] <= 700
    # Same shape, near enough.
    assert abs(shrunk.size[0] / shrunk.size[1] - 700 / 500) < 0.05

    # One that fits goes as it is.
    small = picture(40, 30)
    assert helper.parse_inline(helper.encode_inline(KIND_PNG, TICKET, small, 40000)) == (KIND_PNG, TICKET, small)
    # Not an image at all.
    assert helper.encode_inline(KIND_PNG, TICKET, b"not a picture" * 5000, 40000) is None

    # Transparency goes onto white, and a Windows bitmap survives the round trip.
    clear = Image.new("RGBA", (4, 4), (255, 0, 0, 0))
    out = io.BytesIO()
    clear.save(out, "PNG")
    dib = helper.png_to_dib(out.getvalue())
    back = Image.open(io.BytesIO(helper.dib_to_png(dib)))
    assert back.size == (4, 4) and back.convert("RGB").getpixel((1, 1)) == (255, 255, 255)
    assert helper.trim_png(small + b"\0\0\0") == small

    # A camera's picture, lying on its side with a tag that says so, is
    # turned the right way up wherever it is decoded.
    wide = Image.new("RGB", (60, 20), (10, 200, 30))
    wide.paste((255, 0, 0), (0, 0, 20, 20))
    exif = Image.Exif()
    exif[0x0112] = 6  # the top is on the right: turn a quarter clockwise
    out = io.BytesIO()
    wide.save(out, "JPEG", exif=exif, quality=95)
    sideways = out.getvalue()
    for upright in (
        Image.open(io.BytesIO(helper.to_png(KIND_JPEG, sideways))),
        Image.open(io.BytesIO(helper.shrink(sideways, 40000))),
    ):
        assert upright.size == (20, 60)
        # What was the left end is the top.
        red, green, blue = upright.convert("RGB").getpixel((10, 5))
        assert red > 200 and green < 90 and blue < 90, (red, green, blue)
        red, green, blue = upright.convert("RGB").getpixel((10, 50))
        assert red < 90 and green > 150, (red, green, blue)
    assert Image.open(io.BytesIO(helper.to_png(KIND_JPEG, sideways))).format == "PNG"

    # Sixteen-bit grey keeps its greys instead of going white.
    grey = Image.new("I;16", (8, 8))
    grey.putdata([20000] * 64)
    out = io.BytesIO()
    grey.save(out, "PNG")
    for made in (helper.shrink(out.getvalue(), 40000), b"BM" + bytes(12) + helper.png_to_dib(out.getvalue())):
        level = Image.open(io.BytesIO(made)).convert("L").getpixel((4, 4))
        assert 70 <= level <= 86, level

    # A CMYK JPEG, as a print shop makes them, becomes a PNG without raising.
    ink = Image.new("CMYK", (10, 10), (0, 255, 255, 0))
    out = io.BytesIO()
    ink.save(out, "JPEG")
    red, green, blue = Image.open(io.BytesIO(helper.to_png(KIND_JPEG, out.getvalue()))).convert("RGB").getpixel((5, 5))
    assert red > 200 and green < 60 and blue < 60


def test_addresses() -> None:
    assert helper.usable(["127.0.0.1", "fe80::1%en0", "0.0.0.0", "::1", "fd00::2", "10.1.2.3", "10.1.2.3"]) == [
        "10.1.2.3",
        "fd00::2",
    ]
    listing = json.dumps(
        [
            {"ifname": "lo", "flags": ["LOOPBACK", "UP"], "addr_info": [{"family": "inet", "local": "127.0.0.1"}]},
            {
                "ifname": "wlan0",
                "flags": ["BROADCAST", "UP", "LOWER_UP"],
                "addr_info": [
                    {"family": "inet", "local": "192.168.1.9"},
                    {"family": "inet6", "local": "fd00::9"},
                    {"family": "inet6", "local": "fe80::9"},
                ],
            },
            {"ifname": "eth0", "flags": ["BROADCAST", "UP"], "addr_info": [{"family": "inet", "local": "10.0.0.9"}]},
            {"ifname": "eth1", "flags": ["BROADCAST"], "addr_info": [{"family": "inet", "local": "10.9.9.9"}]},
        ]
    )
    # Every interface that is up, not only the one the default route uses.
    assert helper.usable(helper.parse_interfaces(listing)) == ["192.168.1.9", "10.0.0.9", "fd00::9"]
    print("  this computer's addresses:", helper.local_addresses())


# ---- The stream ----


class Sink:
    """A writer that keeps what it is given."""

    def __init__(self) -> None:
        self.data = b""

    def write(self, data: bytes) -> None:
        self.data += data

    async def drain(self) -> None:
        pass


async def read_records(records: list[bytes], key: bytes = KEY, ticket: bytes = TICKET, sink=None) -> bytes:
    reader = asyncio.StreamReader()
    reader.feed_data(b"".join(records))
    reader.feed_eof()
    return await helper.read_content(reader, sink, key, ticket)


async def fails(records: list[bytes], **how) -> bool:
    sink = Sink()
    try:
        await read_records(records, sink=sink, **how)
    except TransferError:
        # Nothing that failed is ever said to have been taken.
        return sink.data == b""
    return False


async def test_stream() -> None:
    content = bytes(n & 0xFF for n in range(200000))
    records = list(helper.seal(KEY, TICKET, content))
    assert len(records) == 4
    sink = Sink()
    assert await read_records(records, sink=sink) == content
    # Said only once the final record has opened.
    assert sink.data == helper.TAKEN
    assert await read_records(list(helper.seal(KEY, TICKET, b""))) == b""

    assert await fails(records, key=bytes(32))
    assert await fails(records, ticket=bytes(8))
    # Cut off before the final record, and in the middle of one.
    assert await fails(records[:-1])
    assert await fails([records[0][:100]])
    # Tampered with, reordered, and a final record passed off as not final.
    spoiled = bytearray(records[1])
    spoiled[40] ^= 1
    assert await fails([records[0], bytes(spoiled)] + records[2:])
    assert await fails([records[1], records[0]] + records[2:])
    assert await fails(records[:-1] + [b"\0" + records[-1][1:]])
    # A record claiming more than a record may hold.
    assert await fails([bytes([0]) + (helper.RECORD_MAX + 17).to_bytes(4, "little") + bytes(100)])

    # A `last` byte that is neither of the two it may be, however well sealed.
    from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

    odd = ChaCha20Poly1305(KEY).encrypt(bytes(12), b"odd", TICKET + bytes([2]))
    assert await fails([bytes([2]) + len(odd).to_bytes(4, "little") + odd])

    # More than anyone should be sending.
    limit = helper.MAX_CONTENT
    helper.MAX_CONTENT = 150000
    try:
        assert await fails(records)
        assert await read_records(list(helper.seal(KEY, TICKET, content[:150000]))) == content[:150000]
    finally:
        helper.MAX_CONTENT = limit


async def test_network() -> None:
    content = picture(300, 200, noisy=True)
    source, receiver = Endpoint(), Endpoint()
    await source.start()
    await receiver.start()
    try:
        source.offering = Offering(KIND_PNG, lambda: content)
        offer = Offer(KIND_PNG, source.offering.ticket, source.offering.key, source.port, ["127.0.0.1"])
        assert await receiver.get(offer) == content

        # The first address that answers is the one used.
        both = Offer(KIND_PNG, offer.ticket, offer.key, source.port, ["127.0.0.1", "::1"])
        assert await receiver.get(both) == content

        # Not the copy on offer, the wrong key, nobody listening.
        assert await receiver.get(Offer(KIND_PNG, bytes(8), offer.key, source.port, ["127.0.0.1"])) is None
        assert await receiver.get(Offer(KIND_PNG, offer.ticket, bytes(32), source.port, ["127.0.0.1"])) is None
        assert await receiver.get(Offer(KIND_PNG, offer.ticket, offer.key, 1, ["127.0.0.1"])) is None
        assert await receiver.get(Offer(KIND_PNG, offer.ticket, offer.key, source.port, [])) is None

        # The other way round: the source connects and hands it over, and
        # knows it was taken.
        brought: list[bytes] = []
        receiver.awaiting = (offer.ticket, offer.key, brought.append)
        assert await source.put(["127.0.0.1"], receiver.port, source.offering) is True
        assert brought == [content]

        # A copy nobody asked for is not taken, and the source can tell.
        brought.clear()
        receiver.awaiting = (bytes(8), offer.key, brought.append)
        assert await source.put(["127.0.0.1"], receiver.port, source.offering) is False
        receiver.awaiting = None
        assert await source.put(["127.0.0.1"], receiver.port, source.offering) is False
        assert not brought
        assert await source.put(["127.0.0.1"], 1, source.offering) is False
    finally:
        await source.stop()
        await receiver.stop()


async def test_taken_or_not() -> None:
    """What the source makes of every way a stream can end."""
    content = bytes(3_000_000)
    offering = Offering(KIND_PNG, lambda: content, TICKET, KEY)
    endpoint = Endpoint()
    seen = []

    async def serve(behaviour) -> tuple:
        # With little room to receive into, as on a link that is the slow
        # part, so that what has been written has mostly been read.
        import socket

        listener = socket.create_server(("127.0.0.1", 0))
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
        server = await asyncio.start_server(behaviour, sock=listener)
        return server, listener.getsockname()[1]

    async def reads_and_leaves(reader, writer) -> None:
        # Everything is read, and the connection closed, without a word.
        try:
            await reader.readexactly(14)
            await helper.read_content(reader, None, KEY, TICKET)
        finally:
            writer.close()

    async def reads_and_says_so(reader, writer) -> None:
        await reader.readexactly(14)
        await helper.read_content(reader, writer, KEY, TICKET)
        writer.close()

    async def says_something_else(reader, writer) -> None:
        await reader.readexactly(14)
        await helper.read_content(reader, None, KEY, TICKET)
        writer.write(b"\x00")
        await writer.drain()
        writer.close()

    async def never_reads(reader, writer) -> None:
        await asyncio.sleep(3600)

    class Slowly:
        """A reader that takes its time over every piece."""

        def __init__(self, reader) -> None:
            self.reader = reader

        async def read(self, count: int) -> bytes:
            await asyncio.sleep(0.004)
            return await self.reader.read(count)

    async def reads_slowly(reader, writer) -> None:
        await reader.readexactly(14)
        await helper.read_content(Slowly(reader), writer, KEY, TICKET)
        writer.close()

    idle = helper.IDLE_SECONDS
    helper.IDLE_SECONDS = 0.3
    try:
        for behaviour, taken in (
            (reads_and_says_so, True),
            (reads_and_leaves, False),
            (says_something_else, False),
            (never_reads, False),
            (reads_slowly, True),
        ):
            server, port = await serve(behaviour)
            started = time.monotonic()
            assert await endpoint.put(["127.0.0.1"], port, offering) is taken, behaviour.__name__
            took = time.monotonic() - started
            if behaviour is never_reads:
                # Given up on for making no progress, not waited on for ever.
                assert 0.25 <= took < 3, took
            if behaviour is reads_slowly:
                # Slow is not stalled: the whole of it took longer than any
                # one wait is allowed to.
                assert took > helper.IDLE_SECONDS, took
            server.close()

        # The same from the other side: a source that stops part way through
        # is given up on, and one that is merely slow is not.
        records = list(helper.seal(KEY, TICKET, content[:400_000]))

        async def stalls(reader, writer) -> None:
            await reader.readexactly(14)
            writer.write(records[0])
            await writer.drain()
            await asyncio.sleep(3600)

        async def dawdles(reader, writer) -> None:
            await reader.readexactly(14)
            for record in records:
                writer.write(record)
                await writer.drain()
                await asyncio.sleep(0.1)
            assert await reader.read(1) == helper.TAKEN
            seen.append("taken")
            writer.close()

        server, port = await serve(stalls)
        started = time.monotonic()
        assert await endpoint.get(Offer(KIND_PNG, TICKET, KEY, port, ["127.0.0.1"])) is None
        assert 0.25 <= time.monotonic() - started < 3
        server.close()

        server, port = await serve(dawdles)
        started = time.monotonic()
        assert await endpoint.get(Offer(KIND_PNG, TICKET, KEY, port, ["127.0.0.1"])) == content[:400_000]
        assert time.monotonic() - started > helper.IDLE_SECONDS
        await until(lambda: "taken" in seen)
        server.close()
    finally:
        helper.IDLE_SECONDS = idle


async def test_connecting() -> None:
    dialled: list[asyncio.Task] = []

    async def slow(_address: str, _port: int):
        dialled.append(asyncio.current_task())
        await asyncio.sleep(3600)

    async def refused(_address: str, _port: int):
        raise ConnectionRefusedError()

    # Nothing answering is given up on after the time allowed, and what was
    # still being tried is called off.
    endpoint = Endpoint(dial=slow)
    started = time.monotonic()
    assert await endpoint.connect(["10.0.0.1", "10.0.0.2"], 9) is None
    assert helper.CONNECT_SECONDS * 0.8 <= time.monotonic() - started < helper.CONNECT_SECONDS + 1
    await asyncio.sleep(0)
    assert len(dialled) == 2 and all(task.cancelled() for task in dialled)

    # A refusal does not take that long.
    started = time.monotonic()
    assert await Endpoint(dial=refused).connect(["10.0.0.1"], 9) is None
    assert time.monotonic() - started < helper.CONNECT_SECONDS / 2

    # Cancelled part way through, it leaves no attempt running behind it.
    dialled.clear()
    connecting = asyncio.ensure_future(endpoint.connect(["10.0.0.1", "10.0.0.2"], 9))
    await asyncio.sleep(0.05)
    connecting.cancel()
    await asyncio.wait([connecting])
    await asyncio.sleep(0)
    assert connecting.cancelled() and len(dialled) == 2 and all(task.cancelled() for task in dialled)

    # Of two that answer, one is kept and the other closed.
    closed = []

    class Writer:
        def close(self) -> None:
            closed.append(self)

    async def answers(_address: str, _port: int):
        return object(), Writer()

    link = await Endpoint(dial=answers).connect(["10.0.0.1", "10.0.0.2"], 9)
    await asyncio.sleep(0)
    assert link is not None and len(closed) == 1 and closed[0] is not link[1]


# ---- From one computer to the other ----


async def test_text_still_goes_through_the_keyboard() -> None:
    async with World() as world:
        world.boards[0].copy(Clip("just words\r\nand more"))
        world.keyboard.select(1)
        await until(lambda: world.boards[1].clip.text == "just words\nand more")
        assert acks(world.keyboard, 1) == [world.keyboard.clip["crc"]]
        assert not opaque_begins(world.keyboard, 0) and not holds(world.keyboard, 1)

        # What a helper put on the clipboard itself is not sent back.
        await asyncio.sleep(0.2)
        assert world.keyboard.origin == 0 and not world.keyboard.frames(1, BEGIN)

        # A concealed item is not carried, whatever it holds, and takes what
        # was there with it.
        world.boards[0].copy(Clip("hunter2", private=True))
        await until(lambda: world.keyboard.clip is None)
        await asyncio.sleep(0.1)
        assert world.keyboard.frames(0, CLEAR) and len(world.keyboard.frames(0, BEGIN)) == 1
        assert world.boards[1].clip.text == "just words\nand more"

        # Half a surrogate pair goes as a question mark, and nothing falls over.
        world.boards[0].copy(Clip("broken \ud83d pair"))
        await until(lambda: world.keyboard.clip and world.keyboard.clip["bytes"] == b"broken ? pair")


async def test_hello() -> None:
    idle = helper.DELIVERY_IDLE_SECONDS
    helper.DELIVERY_IDLE_SECONDS = 0.3
    try:
        # A link slow enough that a delivery outlasts several HELLOs' worth
        # of time.
        async with World(FakeKeyboard(pace=0.002)) as world:
            # With nothing going on, the helper keeps saying it is there.
            said = len(world.keyboard.frames(1, HELLO))
            await asyncio.sleep(helper.HELLO_SECONDS * 3)
            assert len(world.keyboard.frames(1, HELLO)) >= said + 2

            # Not while a clip is on its way to it: the keyboard would start
            # the delivery again, every time.
            text = "long enough to take a while " * 500
            world.boards[0].copy(Clip(text))
            await until(lambda: world.keyboard.clip)
            # Started just after it has said one, so that the next is not due
            # until the delivery is well under way.
            said = len(world.keyboard.frames(1, HELLO))
            await until(lambda: len(world.keyboard.frames(1, HELLO)) > said)
            world.keyboard.restarts = 0
            began = asyncio.get_running_loop().time()
            world.keyboard.select(1)
            await until(lambda: world.boards[1].clip.text == text, timeout=15)
            ended = world.keyboard.when(1, ACK)[0]
            # It took long enough for several to have been due.
            assert ended - began > helper.HELLO_SECONDS * 3, ended - began
            assert not [at for at in world.keyboard.when(1, HELLO) if began < at < ended]
            assert world.keyboard.restarts == 0

            # A delivery the keyboard gives up on part way, without a word,
            # does not silence the helper for good.
            world.keyboard.select(0)
            world.boards[0].copy(Clip("another long one " * 800))
            await until(lambda: world.keyboard.clip and world.keyboard.clip["bytes"].startswith(b"another"))
            world.keyboard.select(1)
            await until(lambda: world.bridges[1].assembler.active)
            world.keyboard.select(0)
            await asyncio.sleep(0.05)
            assert world.bridges[1].assembler.active and world.bridges[1].busy()
            said = len(world.keyboard.frames(1, HELLO))
            await asyncio.sleep(helper.DELIVERY_IDLE_SECONDS + helper.HELLO_SECONDS * 2)
            assert not world.bridges[1].busy()
            assert len(world.keyboard.frames(1, HELLO)) > said
    finally:
        helper.DELIVERY_IDLE_SECONDS = idle


async def test_a_narrow_link() -> None:
    # The least a Bluetooth link carries: 20 bytes a write.
    async with World(FakeKeyboard(cap=20), dials=(None, blocked)) as world:
        image = picture(120, 80)
        world.boards[0].copy(Clip(None, image=image, form="png"))
        await until(lambda: world.keyboard.clip)
        world.keyboard.select(1)
        await until(lambda: world.boards[1].clip.image == image)
        assert all(len(frame) <= 20 for _sender, frame in world.keyboard.written)
        # The WANT was cut down to the one address there was room for.
        want = world.keyboard.frames(1, RELAY)[0]
        assert len(want) <= 20 and helper.parse_want(want[1:])[2] == ["127.0.0.1"]

    async with World(FakeKeyboard(cap=62)) as world:
        world.boards[0].copy(Clip("x" * 5000))
        await until(lambda: world.keyboard.clip)
        # And a wider one is filled.
        assert max(len(frame) for frame in world.keyboard.frames(0, DATA)) == 62


async def test_fetched_over_the_network() -> None:
    image = picture(320, 200)
    async with World() as world:
        world.boards[0].copy(Clip(None, image=image, form="png"))
        await until(lambda: world.keyboard.clip)
        offer = Offer.parse(world.keyboard.clip["bytes"])
        assert world.keyboard.clip["opaque"] and offer.kind == KIND_PNG
        assert offer.port == world.bridges[0].endpoint.port and offer.addresses == ["127.0.0.1"]
        crc = world.keyboard.clip["crc"]

        world.keyboard.select(1)
        await until(lambda: world.boards[1].clip.image == image)
        await until(lambda: acks(world.keyboard, 1))
        assert world.boards[1].clip.form == "png"
        assert acks(world.keyboard, 1) == [crc]
        # The keyboard was asked to keep pastes back first, and not after.
        assert holds(world.keyboard, 1)[0] == HOLD_SOON and world.keyboard.honoured[0] == (1, HOLD_SOON)
        await asyncio.sleep(0.2)
        assert not any(frame[0] == HOLD for frame in after_last(world.keyboard, 1, ACK))
        assert not world.keyboard.held(1)
        assert not world.keyboard.frames(1, RELAY)
        # And the image was not offered back.
        assert not world.keyboard.frames(1, BEGIN) and world.bridges[1].fetch is None

        # Only the latest copy stays on offer.
        world.keyboard.select(0)
        assert world.bridges[0].endpoint.offering is not None
        world.boards[0].copy(Clip("short"))
        await until(lambda: world.keyboard.clip and world.keyboard.clip["bytes"] == b"short")
        assert world.bridges[0].endpoint.offering is None

        # Text too long for the keyboard goes the same way as an image.
        text = "long " * 6000
        world.boards[0].copy(Clip(text))
        await until(lambda: world.keyboard.clip and world.keyboard.clip["opaque"])
        assert Offer.parse(world.keyboard.clip["bytes"]).kind == KIND_TEXT
        world.keyboard.select(1)
        await until(lambda: world.boards[1].clip.text == text)

        # A JPEG is offered as one, and a bitmap as the PNG it becomes. On
        # the clipboard at the other end both are PNGs.
        from PIL import Image

        jpeg = io.BytesIO()
        Image.open(io.BytesIO(image)).save(jpeg, "JPEG")
        world.keyboard.select(0)
        world.boards[0].copy(Clip(None, image=jpeg.getvalue(), form="jpeg"))
        await until(lambda: world.keyboard.clip and Offer.parse(world.keyboard.clip["bytes"]).kind == KIND_JPEG)
        world.keyboard.select(1)
        await until(lambda: world.boards[1].clip.image and world.boards[1].clip.image != image)
        assert Image.open(io.BytesIO(world.boards[1].clip.image)).format == "PNG"

        world.keyboard.select(0)
        world.boards[0].copy(Clip(None, image=helper.png_to_dib(image), form="dib"))
        await until(lambda: world.keyboard.clip and Offer.parse(world.keyboard.clip["bytes"]).kind == KIND_PNG)
        before = world.boards[1].count
        world.keyboard.select(1)
        await until(lambda: world.boards[1].count > before)
        assert Image.open(io.BytesIO(world.boards[1].clip.image)).size == (320, 200)


async def test_a_long_download() -> None:
    image = picture(64, 64)
    async with World() as world:
        world.boards[0].copy(Clip(None, image=image, form="png"))
        await until(lambda: world.keyboard.clip)
        crc = world.keyboard.clip["crc"]

        # The source answers at once and then takes its time over the content.
        def eventually() -> bytes:
            time.sleep(1.0)
            return image

        world.bridges[0].endpoint.offering.produce = eventually
        world.keyboard.select(1)
        await until(lambda: world.boards[1].clip.image == image)
        await until(lambda: acks(world.keyboard, 1))

        # It came by the first way, with no asking for another.
        assert acks(world.keyboard, 1) == [crc] and not world.keyboard.frames(1, RELAY)
        # A paste was held for it only for as long as the quick ways would
        # have had: after that the keyboard was told not to wait.
        held = holds(world.keyboard, 1)
        marks = world.keyboard.when(1, HOLD)
        quick = helper.CONNECT_SECONDS + helper.PUT_WAIT_SECONDS
        assert held[0] == HOLD_SOON and held[-1] == 0 and held == sorted(held, reverse=True)
        turned = marks[held.index(0)] - marks[0]
        assert quick - 0.02 <= turned <= quick + helper.HOLD_SECONDS + 0.05, turned
        # And it never went longer without a HOLD than the keyboard waits for one.
        assert longest_wait_for_a_hold(world.keyboard, 1) < 4 * helper.HOLD_SECONDS


async def test_holds_run_through_a_slow_clipboard() -> None:
    image = picture(64, 64)
    for dials in ((None, None), (blocked, blocked)):
        async with World(dials=dials) as world:
            # A clipboard that takes longer over a write than the keyboard
            # waits to hear HOLD again.
            world.boards[1].slow = 10 * helper.HOLD_SECONDS
            world.boards[0].copy(Clip(None, image=image, form="png"))
            await until(lambda: world.keyboard.clip)
            world.keyboard.select(1)
            await until(lambda: acks(world.keyboard, 1), timeout=10)

            assert world.boards[1].clip.image == image
            assert len(holds(world.keyboard, 1)) >= 8
            assert longest_wait_for_a_hold(world.keyboard, 1) < 4 * helper.HOLD_SECONDS
            # Nor did it say HELLO while the write dragged on, which would
            # have had the keyboard start the delivery over.
            own = order(world.keyboard, 1)
            first_hold = next(index for index, frame in enumerate(own) if frame[0] == HOLD)
            last_ack = max(index for index, frame in enumerate(own) if frame[0] == ACK)
            assert not any(frame[0] == HELLO for frame in own[first_hold:last_ack])
            assert world.keyboard.restarts == 0
            await asyncio.sleep(0.2)
            assert not any(frame[0] == HOLD for frame in after_last(world.keyboard, 1, ACK))
            assert not world.keyboard.held(1)


async def test_brought_when_it_cannot_be_fetched() -> None:
    image = picture(320, 200)
    # The receiver cannot connect to the source; the source can to the receiver.
    async with World(dials=(None, blocked)) as world:
        world.boards[0].copy(Clip(None, image=image, form="png"))
        await until(lambda: world.keyboard.clip)
        crc = world.keyboard.clip["crc"]
        world.keyboard.select(1)
        await until(lambda: world.boards[1].clip.image == image)
        await until(lambda: acks(world.keyboard, 1))

        assert acks(world.keyboard, 1) == [crc]
        wants = world.keyboard.frames(1, RELAY)
        assert len(wants) == 1
        ticket, port, addresses = helper.parse_want(wants[0][1:])
        assert ticket == Offer.parse(world.keyboard.clip["bytes"]).ticket
        assert port == world.bridges[1].endpoint.port and addresses == ["127.0.0.1"]
        # Nothing had to come through the keyboard.
        await asyncio.sleep(0.2)
        assert len(opaque_begins(world.keyboard, 0)) == 1
        assert set(holds(world.keyboard, 1)) == {HOLD_SOON}

    # Something at the receiver's address accepts the connection, reads all
    # it is sent, and never says it took it. The source does not take that
    # for success, and sends the copy the other way.
    idle = helper.IDLE_SECONDS
    helper.IDLE_SECONDS = 0.3
    try:
        async with World(dials=(None, blocked)) as world:

            async def reads_and_says_nothing(reader, writer) -> None:
                await reader.read()
                writer.close()

            world.bridges[1].endpoint.server.close()
            await world.bridges[1].endpoint.server.wait_closed()
            deaf = await asyncio.start_server(reads_and_says_nothing, "127.0.0.1", world.bridges[1].endpoint.port)
            world.boards[0].copy(Clip(None, image=image, form="png"))
            await until(lambda: world.keyboard.clip)
            world.keyboard.select(1)
            await until(lambda: world.boards[1].clip.image == image)
            assert world.keyboard.clip["bytes"][0] == helper.INLINE
            deaf.close()
    finally:
        helper.IDLE_SECONDS = idle


async def test_through_the_keyboard() -> None:
    from PIL import Image

    image = picture(700, 500, noisy=True)
    async with World(dials=(blocked, blocked)) as world:
        # Through a real keyboard this takes seconds. Here the source is
        # held up instead, for long enough that the receiver stops expecting
        # it to come quickly.
        answer = world.bridges[0].answer

        async def slowly(*arguments) -> None:
            await asyncio.sleep(helper.PUT_WAIT_SECONDS + 0.4)
            await answer(*arguments)

        world.bridges[0].answer = slowly

        world.boards[0].copy(Clip(None, image=image, form="png"))
        await until(lambda: world.keyboard.clip)
        offer_crc = world.keyboard.clip["crc"]
        world.keyboard.select(1)
        await until(lambda: world.boards[1].clip.image is not None, timeout=20)
        await until(lambda: acks(world.keyboard, 1))

        # What arrived is the picture, smaller, and it fitted.
        assert Image.open(io.BytesIO(world.boards[1].clip.image)).size[0] < 700
        inline = world.keyboard.clip
        assert inline["opaque"] and inline["crc"] != offer_crc and len(inline["bytes"]) <= helper.INLINE_BUDGET
        assert inline["bytes"][0] == helper.INLINE and inline["bytes"][1] == KIND_JPEG
        # It is that clip which is acknowledged, not the offer.
        assert acks(world.keyboard, 1) == [inline["crc"]]

        # Pastes were kept back while it might still come quickly, then
        # turned away while it trickled through, and left alone afterwards.
        held = holds(world.keyboard, 1)
        assert held[0] == HOLD_SOON and held[-1] == 0 and HOLD_OFF not in held
        assert held == sorted(held, reverse=True)
        assert longest_wait_for_a_hold(world.keyboard, 1) < 4 * helper.HOLD_SECONDS
        await asyncio.sleep(0.2)
        assert not any(frame[0] == HOLD for frame in after_last(world.keyboard, 1, ACK))
        # No HELLO while it was going on, which would have restarted the delivery.
        own = order(world.keyboard, 1)
        first_hold = next(index for index, frame in enumerate(own) if frame[0] == HOLD)
        last_ack = max(index for index, frame in enumerate(own) if frame[0] == ACK)
        assert not any(frame[0] == HELLO for frame in own[first_hold:last_ack])
        assert world.keyboard.restarts == 0
        assert not world.keyboard.frames(1, BEGIN)

        # Text that fits comes through whole.
        text = "wide " * 5000
        world.keyboard.select(0)
        world.boards[0].copy(Clip(text))
        await until(lambda: world.keyboard.clip and world.keyboard.clip["bytes"][0] == helper.OFFER)
        world.keyboard.select(1)
        await until(lambda: world.boards[1].clip.text == text, timeout=20)


async def test_one_answer_at_a_time() -> None:
    async with World(dials=(blocked, blocked)) as world:
        answered = []
        answer = world.bridges[0].answer

        async def slowly(*arguments) -> None:
            answered.append(arguments)
            await asyncio.sleep(0.3)
            await answer(*arguments)

        world.bridges[0].answer = slowly
        world.boards[0].copy(Clip(None, image=picture(64, 64), form="png"))
        await until(lambda: world.keyboard.clip)
        ticket = Offer.parse(world.keyboard.clip["bytes"]).ticket
        world.keyboard.select(1)

        # The receiver asks, and asks again before the first has been dealt with.
        want = helper.encode_want(ticket, 9, [], 63)
        await world.bridges[0].on_relay(want)
        await world.bridges[0].on_relay(want)
        await until(lambda: world.boards[1].clip.image is not None)
        await asyncio.sleep(0.5)
        assert len(answered) == 1
        assert len(opaque_begins(world.keyboard, 0)) == 2

        # Once it has, a later one is answered afresh.
        await world.bridges[0].on_relay(want)
        await until(lambda: len(answered) == 2)


async def test_gives_up_when_it_cannot_be_had() -> None:
    # Too long to come through the keyboard, with no other way across.
    text = "x" * 50000
    async with World(dials=(blocked, blocked)) as world:
        world.keyboard.select(1)
        world.boards[1].copy(Clip("what was here before"))
        await until(lambda: world.keyboard.clip)
        world.boards[0].copy(Clip(text))
        await until(lambda: world.keyboard.clip and world.keyboard.clip["opaque"])
        crc = world.keyboard.clip["crc"]
        world.keyboard.select(1)
        await until(lambda: acks(world.keyboard, 1))

        gone = world.keyboard.frames(0, RELAY)
        assert len(gone) == 1 and gone[0][1] == GONE
        assert holds(world.keyboard, 1)[-1] == HOLD_OFF
        # The offer is acknowledged, so the keyboard stops waiting on it.
        assert acks(world.keyboard, 1) == [crc]
        tail = after_last(world.keyboard, 1, HOLD)
        assert [frame[0] for frame in tail if frame[0] != HELLO] == [ACK]
        assert world.boards[1].clip.text == "what was here before"
        assert world.bridges[1].fetch is None and not world.keyboard.held(1)

    # The helper it came from has gone: the WANT has nowhere to go, and
    # neither has the shorter one sent after it.
    async with World(dials=(blocked, blocked)) as world:
        world.boards[0].copy(Clip(None, image=picture(64, 64), form="png"))
        await until(lambda: world.keyboard.clip)
        crc = world.keyboard.clip["crc"]
        world.keyboard.helpers.pop(0)
        world.keyboard.select(1)
        await until(lambda: acks(world.keyboard, 1))
        wants = [helper.parse_want(frame[1:]) for frame in world.keyboard.frames(1, RELAY)]
        assert [len(addresses) for _t, _p, addresses in wants] == [1, 0]
        assert holds(world.keyboard, 1)[-1] == HOLD_OFF and acks(world.keyboard, 1) == [crc]

    # A copy that has since been replaced on the source: it says so.
    async with World(dials=(blocked, blocked)) as world:
        world.boards[0].copy(Clip(None, image=picture(64, 64), form="png"))
        await until(lambda: world.keyboard.clip)
        world.bridges[0].endpoint.offering = None
        world.keyboard.select(1)
        await until(lambda: acks(world.keyboard, 1))
        assert world.keyboard.frames(0, RELAY)[0][1] == GONE
        assert holds(world.keyboard, 1)[-1] == HOLD_OFF


async def test_nothing_comes() -> None:
    # The source's helper never answers at all.
    waits = helper.INLINE_WAIT_SECONDS
    helper.INLINE_WAIT_SECONDS = 0.6
    try:
        async with World(dials=(blocked, blocked)) as world:
            world.boards[0].copy(Clip(None, image=picture(64, 64), form="png"))
            await until(lambda: world.keyboard.clip)
            crc = world.keyboard.clip["crc"]

            async def deaf(_datagram: bytes) -> None:
                pass

            world.bridges[0].on_relay = deaf
            world.keyboard.select(1)
            await until(lambda: acks(world.keyboard, 1))
            held = holds(world.keyboard, 1)
            assert held[0] == HOLD_SOON and 0 in held and held[-1] == HOLD_OFF
            # Kept up for the whole of the wait, not said once and left.
            assert held.count(HOLD_SOON) >= 3 and held.count(0) >= 3
            assert acks(world.keyboard, 1) == [crc]
    finally:
        helper.INLINE_WAIT_SECONDS = waits


async def test_local_copy_abandons_the_fetch() -> None:
    # The fetch is left hanging on a connection that never completes: nothing
    # has been asked of the source yet.
    async with World(dials=(None, hangs)) as world:
        world.boards[0].copy(Clip(None, image=picture(64, 64), form="png"))
        await until(lambda: world.keyboard.clip)
        crc = world.keyboard.clip["crc"]
        world.keyboard.select(1)
        await until(lambda: world.bridges[1].fetch is not None)

        world.boards[1].copy(Clip("copied here instead"))
        await until(lambda: world.keyboard.clip and not world.keyboard.clip["opaque"])
        assert world.bridges[1].fetch is None
        assert world.keyboard.origin == 1 and world.keyboard.clip["bytes"] == b"copied here instead"
        assert holds(world.keyboard, 1)[-1] == HOLD_OFF
        assert crc not in acks(world.keyboard, 1) and not world.keyboard.frames(1, RELAY)
        await asyncio.sleep(0.2)
        assert not any(frame[0] in (HOLD, RELAY) for frame in after_last(world.keyboard, 1, END))
        assert world.boards[1].clip.text == "copied here instead"

    # It has been asked for, and the source is getting it ready to send
    # through the keyboard. Sent now, it would replace the newer copy there.
    async with World(dials=(blocked, blocked)) as world:
        answer = world.bridges[0].answer
        answering = []

        async def slowly(*arguments) -> None:
            answering.append(arguments)
            await asyncio.sleep(0.4)
            await answer(*arguments)

        world.bridges[0].answer = slowly
        world.boards[0].copy(Clip(None, image=picture(64, 64), form="png"))
        await until(lambda: world.keyboard.clip)
        ticket = Offer.parse(world.keyboard.clip["bytes"]).ticket
        world.keyboard.select(1)
        await until(lambda: answering)

        world.boards[1].copy(Clip("copied here instead"))
        await until(lambda: world.keyboard.clip and world.keyboard.clip["bytes"] == b"copied here instead")
        await asyncio.sleep(0.6)

        # CANCEL, then HOLD OFF, then the new copy, in that order.
        own = [frame for frame in order(world.keyboard, 1) if frame[0] in (RELAY, HOLD, BEGIN)]
        tail = own[-3:]
        assert tail[0] == bytes([RELAY, CANCEL]) + ticket
        assert tail[1] == bytes([HOLD, HOLD_OFF]) and tail[2][0] == BEGIN
        # The source stopped offering it and sent nothing more for it.
        assert world.bridges[0].endpoint.offering is None
        assert len(opaque_begins(world.keyboard, 0)) == 1
        assert world.keyboard.origin == 1 and world.keyboard.clip["bytes"] == b"copied here instead"
        assert world.bridges[1].abandoned == ticket
        assert world.boards[1].clip.text == "copied here instead"


async def test_an_inline_no_longer_wanted() -> None:
    async with World(dials=(blocked, blocked)) as world:
        # A source that does not heed CANCEL, or had already sent.
        heeds = world.bridges[0].on_relay

        async def unheeding(datagram: bytes) -> None:
            if datagram[0] != CANCEL:
                await heeds(datagram)

        answer = world.bridges[0].answer

        async def slowly(*arguments) -> None:
            await asyncio.sleep(0.3)
            await answer(*arguments)

        world.bridges[0].on_relay = unheeding
        world.bridges[0].answer = slowly
        world.boards[0].copy(Clip(None, image=picture(64, 64), form="png"))
        await until(lambda: world.keyboard.clip)
        world.keyboard.select(1)
        await until(lambda: world.keyboard.frames(1, RELAY))

        world.boards[1].copy(Clip("copied here instead"))
        await until(lambda: world.keyboard.clip and world.keyboard.clip["bytes"][0] == helper.INLINE)
        inline = world.keyboard.clip["crc"]
        await until(lambda: inline in acks(world.keyboard, 1))

        # Acknowledged, so that no paste waits on it, and not put on the clipboard.
        await asyncio.sleep(0.2)
        assert world.boards[1].clip.text == "copied here instead" and world.boards[1].clip.image is None
        assert world.bridges[1].fetch is None and not world.keyboard.held(1)

        # The next thing copied over there is wanted as usual.
        image = picture(32, 32)
        world.bridges[0].answer = answer
        world.keyboard.select(0)
        world.boards[0].copy(Clip(None, image=image, form="png"))
        await until(lambda: world.keyboard.clip and world.keyboard.clip["bytes"][0] == helper.OFFER)
        world.keyboard.select(1)
        await until(lambda: world.boards[1].clip.image == image)


async def test_a_newer_clip_replaces_the_fetch() -> None:
    async with World(dials=(None, hangs)) as world:
        world.boards[0].copy(Clip(None, image=picture(64, 64), form="png"))
        await until(lambda: world.keyboard.clip)
        world.keyboard.select(1)
        await until(lambda: world.bridges[1].fetch is not None)

        # Something else is copied on the source while the fetch is running.
        world.boards[0].copy(Clip("newer"))
        await until(lambda: world.boards[1].clip.text == "newer")
        await until(lambda: acks(world.keyboard, 1))
        assert world.bridges[1].fetch is None
        assert acks(world.keyboard, 1) == [zlib.crc32(b"newer")]
        # Dropped without a word: what replaced it says all there is to say.
        assert HOLD_OFF not in holds(world.keyboard, 1) and not world.keyboard.frames(1, RELAY)
        await asyncio.sleep(0.2)
        assert not any(frame[0] == HOLD for frame in after_last(world.keyboard, 1, ACK))


async def test_opaque_clips_out_of_the_blue() -> None:
    async with World() as world:
        world.keyboard.select(1)
        message = helper.encode_inline(KIND_TEXT, TICKET, b"straight through", 1000)
        await world.bridges[0].send_clip(message, OPAQUE)
        await until(lambda: world.boards[1].clip.text == "straight through")
        await until(lambda: acks(world.keyboard, 1))
        assert acks(world.keyboard, 1) == [zlib.crc32(message)]
        assert not holds(world.keyboard, 1)

        # A message of a kind this helper does not know is acknowledged, so
        # that no paste is kept waiting on it, and otherwise left alone.
        unknown = bytes([0x7F]) + bytes(60)
        await world.bridges[0].send_clip(unknown, OPAQUE)
        await until(lambda: zlib.crc32(unknown) in acks(world.keyboard, 1))
        assert world.boards[1].clip.text == "straight through"

        # A clip that lands before this helper has had its first look at the
        # clipboard is not mistaken for older than what is on it.
        early = Bridge(world.keyboard.clients[1], FakeClipboard(), "M0110", world.bridges[1].endpoint)
        early.clipboard.copy(Clip("from before the helper started"))
        assert await early.place(KIND_TEXT, b"early", 7, "{}") == helper.PLACED
        assert early.clipboard.clip.text == "early"

        # So is one that is not an image at all, though it says it is.
        broken = bytes([helper.INLINE, KIND_PNG]) + TICKET + b"not a picture"
        await world.bridges[0].send_clip(broken, OPAQUE)
        await asyncio.sleep(0.3)
        assert world.boards[1].clip.text == "straight through"


async def test_a_newer_copy_overtakes_one_being_sent() -> None:
    async with World(dials=(blocked, blocked)) as world:
        world.keyboard.select(1)
        first = asyncio.ensure_future(world.bridges[0].send_clip(b"a" * 6000, 0))
        await asyncio.sleep(0)
        assert await world.bridges[0].send_clip(b"second", 0)
        assert not await first
        await until(lambda: world.boards[1].clip.text == "second")
        assert world.keyboard.clip["bytes"] == b"second"

        # The same when it is the clipboard that says so: a long one being
        # sent is dropped for the short one copied after it.
        world.keyboard.select(0)
        world.keyboard.clients[0].lag = 0.002
        world.boards[0].copy(Clip("b" * 16000))
        await until(lambda: len(world.keyboard.frames(0, BEGIN)) == 3)
        world.boards[0].copy(Clip("third"))
        await until(lambda: world.keyboard.clip and world.keyboard.clip["bytes"] == b"third")
        own = order(world.keyboard, 0)
        begins = [index for index, frame in enumerate(own) if frame[0] == BEGIN]
        assert len(begins) == 4
        long_one = [frame for frame in own[begins[2] : begins[3]] if frame[0] == DATA]
        assert 0 < len(long_one) < 16000 // 59
        # Nothing of it followed the copy that replaced it.
        assert [frame[0] for frame in own[begins[3] :] if frame[0] in (BEGIN, DATA, END)] == [BEGIN, DATA, END]


async def test_older_firmware_carries_text_only() -> None:
    async with World(FakeKeyboard(version=1, max_len=4096, max_opaque=0)) as world:
        assert world.bridges[0].max_opaque == 0 and world.bridges[0].max_length == 4096
        world.keyboard.select(1)

        world.boards[0].copy(Clip("short enough"))
        await until(lambda: world.boards[1].clip.text == "short enough")

        # An image, and text past what it holds, are not carried at all, and
        # the keyboard is told to drop what it had.
        world.boards[0].copy(Clip(None, image=picture(64, 64), form="png"))
        await until(lambda: world.keyboard.clip is None)
        world.boards[0].copy(Clip("still text"))
        await until(lambda: world.keyboard.clip)
        world.boards[0].copy(Clip("y" * 5000))
        await until(lambda: world.keyboard.clip is None)

        assert not opaque_begins(world.keyboard, 0)
        assert not world.keyboard.frames(0, RELAY) and not world.keyboard.frames(0, HOLD)
        assert world.bridges[0].endpoint.offering is None

    # Firmware that knows opaque clips but has no room for an OFFER with
    # every address in it, and firmware that has just enough.
    for room, offers in ((0, False), (helper.MIN_OPAQUE - 1, False), (helper.MIN_OPAQUE, True)):
        async with World(FakeKeyboard(max_opaque=room)) as world:
            world.boards[0].copy(Clip("kept"))
            await until(lambda: world.keyboard.clip)
            world.boards[0].copy(Clip(None, image=picture(64, 64), form="png"))
            await until(lambda: world.keyboard.clip is None or world.keyboard.clip["opaque"])
            assert bool(opaque_begins(world.keyboard, 0)) is offers, room


# ---- The clipboard's own ways ----


async def test_the_same_thing_is_not_sent_twice() -> None:
    async with World() as world:
        board = world.boards[0]
        board.owner = 77

        def sent() -> int:
            return len(world.keyboard.frames(0, BEGIN))

        board.copy(Clip("once"))
        await until(lambda: sent() == 1)

        # The number moves, as it does when a promised format is rendered.
        # Same owner, same content: not a copy.
        board.count += 1
        await asyncio.sleep(0.15)
        assert sent() == 1 and world.bridges[0].seen == board.count

        # Reading is itself what moves it, on some clipboards.
        board.renders = True
        board.copy(Clip("twice"))
        await until(lambda: sent() == 2)
        await asyncio.sleep(0.15)
        assert sent() == 2 and board.reads <= 3
        board.renders = False

        # Another program copying the same words is a copy.
        board.copy(Clip("twice"), owner=78)
        await until(lambda: sent() == 3)

        # And so is the same program copying them again when the keyboard
        # saw the shortcut go by.
        board.copy(Clip("twice"))
        world.keyboard.notify(0, bytes([helper.POKE]))
        await until(lambda: sent() == 4)

        # A clipboard that could not be looked at is not an empty one: the
        # keyboard keeps what it has, and the copy is picked up when it can be.
        clears = len(world.keyboard.frames(0, CLEAR))
        board.held = 3
        board.copy(Clip("held up"))
        await until(lambda: world.keyboard.clip and world.keyboard.clip["bytes"] == b"held up")
        assert len(world.keyboard.frames(0, CLEAR)) == clears and board.held == 0

    # On a system that cannot say whose a copy is, a clip this helper put
    # there itself is still known for what it is, however late its marker moves.
    async with World() as world:
        world.boards[0].copy(Clip("over the wire"))
        world.keyboard.select(1)
        await until(lambda: world.boards[1].clip.text == "over the wire")
        await asyncio.sleep(0.2)
        world.boards[1].count += 1
        await asyncio.sleep(0.15)
        assert not world.keyboard.frames(1, BEGIN) and world.keyboard.origin == 0

        # Something copied on the receiving computer just before a delivery
        # lands is the newer of the two, and is not written over.
        world.keyboard.select(0)
        world.boards[0].copy(Clip("from afar"))
        await until(lambda: world.keyboard.clip and world.keyboard.clip["bytes"] == b"from afar")
        watching = world.bridges[1].check_clipboard
        seen = []

        async def later(poked: bool) -> None:
            if seen:
                await watching(poked)

        world.bridges[1].check_clipboard = later
        world.boards[1].copy(Clip("typed here first"))
        world.keyboard.select(1)
        await asyncio.sleep(0.3)
        assert world.boards[1].clip.text == "typed here first"
        seen.append(True)
        await until(lambda: world.keyboard.clip and world.keyboard.clip["bytes"] == b"typed here first")


def test_linux_clipboard() -> None:
    """How the Linux clipboard decides things, with the tools it runs played by a table."""

    class Played(LinuxClipboard):
        def __init__(self, tool: str, answers: dict, watching: bool = False, **how) -> None:
            self.answers = answers
            self.ran: list[str] = []
            self.can_watch = watching
            have = {"wl": {"wl-paste", "wl-copy"}, "xclip": {"xclip"}, "xsel": {"xsel"}, "both": {"wl-paste", "wl-copy", "xclip"}}[tool]
            super().__init__(which=lambda name: name if name in have else None, **how)

        def _watch(self) -> bool:
            return self.can_watch

        def _run(self, command, timeout: float = 2):
            wanted = command[-1] if command[-1] != "--list-types" else "TARGETS"
            self.ran.append(wanted)
            answer = self.answers.get(wanted)
            return answer() if callable(answer) else answer

    wayland = {"WAYLAND_DISPLAY": "wayland-0"}

    # Which tool, by what the session offers.
    assert Played("wl", {}, watching=True, environ=wayland).watching
    without = Played("wl", {}, environ=wayland)
    assert without.tool == "wl" and without.poke_only and not without.watching
    through = Played("both", {}, environ={**wayland, "DISPLAY": ":0"})
    assert through.tool == "xclip" and not through.poke_only
    assert Played("both", {}, environ=wayland).poke_only
    assert Played("xclip", {}, environ={"DISPLAY": ":0"}).tool == "xclip"
    assert Played("xsel", {}, environ={}).tool == "xsel"

    # Watched: the count of changes is the marker, and nothing is run to get it.
    watched = Played("wl", {}, watching=True, environ=wayland)
    first = watched.marker()
    watched.changes += 1
    assert watched.marker() != first and not watched.ran

    # Not watched and no xclip: the clipboard is left alone until the
    # keyboard says a copy was made.
    without.answers = {"TARGETS": b"text/plain\n", "text/plain": b"words"}
    idle = without.marker()
    assert without.marker(False) == idle and not without.ran
    assert without.marker(True) != idle and without.ran
    assert without.read().text == "words"

    # Text is asked for by the first acceptable name the owner gives it, and
    # not at all of an owner that offers none: xclip would hand over its
    # image as if it were text.
    board = Played("xclip", {"TARGETS": b"TARGETS\nSTRING\ntext/plain\n", "text/plain": b"plain", "STRING": b"old"}, environ={})
    assert board.read().text == "plain" and "UTF8_STRING" not in board.ran
    board = Played("xclip", {"TARGETS": b"TARGETS\nimage/png\n", "UTF8_STRING": b"\x89PNG", "image/png": b"\x89PNG"}, environ={})
    clip = board.read()
    assert clip.text is None and clip.image == b"\x89PNG" and "UTF8_STRING" not in board.ran
    board = Played("wl", {"TARGETS": b"text/html\ntext/plain;charset=utf-8\nUTF8_STRING\n", "text/plain;charset=utf-8": b"utf8"}, watching=True, environ=wayland)
    assert board.read().text == "utf8"
    board = Played("xclip", {"TARGETS": b"x-kde-passwordManagerHint\nUTF8_STRING\n", "UTF8_STRING": b"secret"}, environ={})
    assert board.read().private and board.read().text is None and board.marker()[0] is True

    # An image whose owner gives the selection a timestamp is told apart by
    # that, and read once per copy.
    stamp = [b"\x01\x00\x00\x00"]
    reads = []

    def image() -> bytes:
        reads.append(1)
        return b"\x89PNG one"

    board = Played(
        "xclip",
        {"TARGETS": b"TIMESTAMP\nTARGETS\nimage/png\n", "TIMESTAMP": lambda: stamp[0], "image/png": image},
        environ={},
    )
    first = board.marker()
    for _ in range(5):
        assert board.marker() == first and board.marker(True) == first
    assert not reads
    assert board.read().image == b"\x89PNG one" and len(reads) == 1
    stamp[0] = b"\x02\x00\x00\x00"
    assert board.marker() != first and len(reads) == 1

    # One that gives none is never asked for one, and has its image read
    # again only every so often, or when a copy was just made.
    reads.clear()
    board = Played("xclip", {"TARGETS": b"TARGETS\nimage/png\n", "image/png": image, "TIMESTAMP": b"\x89PNG one"}, environ={})
    first = board.marker()
    assert board.marker() == first and len(reads) == 1 and "TIMESTAMP" not in board.ran
    board.marker(True)
    assert len(reads) == 2
    board.image_read -= helper.IMAGE_POLL_SECONDS
    board.marker()
    assert len(reads) == 3

    # A timestamp that keeps changing under an image that does not is not
    # believed for long.
    board = Played(
        "xclip",
        {"TARGETS": b"TIMESTAMP\nTARGETS\nimage/png\n", "TIMESTAMP": lambda: stamp[0], "image/png": b"\x89PNG same"},
        environ={},
    )
    for tick in range(5):
        stamp[0] = bytes([tick + 10, 0, 0, 0])
        board.read()
    assert not board.stamps_trusted
    board.ran.clear()
    board.marker()
    assert "TIMESTAMP" not in board.ran


# ---- Bluetooth ----


def test_finding_the_keyboard() -> None:
    def device(address: str, alias: str, connected: bool, paired: bool = True) -> dict:
        props = {"Address": address, "Alias": alias, "Name": alias, "Connected": connected, "Paired": paired}
        return {"org.bluez.Device1": props, "org.freedesktop.DBus.Properties": {}}

    objects = {
        "/org/bluez": {"org.bluez.AgentManager1": {}},
        "/org/bluez/hci0": {"org.bluez.Adapter1": {"Address": "00:11:22:33:44:55", "Powered": True}},
        "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01": device("AA:BB:CC:DD:EE:01", "Mouse", True),
        "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_02": device("AA:BB:CC:DD:EE:02", "M0110", False),
        "/org/bluez/hci1/dev_C8_D1_D8_BD_10_0A": device("C8:D1:D8:BD:10:0A", "M0110", True),
        "/org/bluez/hci1/dev_C8_D1_D8_BD_10_0A/service0010": {"org.bluez.GattService1": {"UUID": "x"}},
    }

    # By name: the one that is connected, on whichever adapter it is.
    address, name, details = helper.bluez_device(objects, "M0110", None)
    assert address == "C8:D1:D8:BD:10:0A" and name == "M0110"
    assert details["path"] == "/org/bluez/hci1/dev_C8_D1_D8_BD_10_0A"
    assert details["props"]["Connected"] is True and details["props"]["Alias"] == "M0110"

    # By address, however it is written, even if the name has been changed.
    address, _name, details = helper.bluez_device(objects, "something else", "aa:bb:cc:dd:ee:02")
    assert address == "AA:BB:CC:DD:EE:02" and details["path"].endswith("EE_02")
    assert helper.bluez_device(objects, "M0111", None) is None
    assert helper.bluez_device(objects, "M0110", "00:00:00:00:00:00") is None
    assert helper.bluez_device({}, "M0110", None) is None

    # What bleak is handed is a device, not an address: given an address it
    # scans for the keyboard first, and a keyboard in use is not advertising.
    from bleak.backends.device import BLEDevice

    made = helper.ble_device(address, "M0110", details)
    assert isinstance(made, BLEDevice) and made.address == address and made.details is details
    assert helper.ble_device("C8:D1:D8:BD:10:0A", "M0110", None).details is None

    if sys.platform.startswith("linux"):
        # bleak's own client takes it as found: the path and properties are
        # in hand, which is what it checks before deciding whether to scan.
        from bleak import BleakClient

        backend = BleakClient(helper.ble_device(*helper.bluez_device(objects, "M0110", None)))._backend
        assert backend._device_path == "/org/bluez/hci1/dev_C8_D1_D8_BD_10_0A"
        assert backend._device_info["Alias"] == "M0110"
        print("  bleak's BlueZ client took the device without a scan")


async def test_letting_go() -> None:
    """Leaving the keyboard connected when the helper is done with it."""
    if sys.platform == "win32":
        return
    done = []

    class Bus:
        def disconnect(self) -> None:
            done.append("bus closed")

        async def wait_for_disconnect(self) -> None:
            done.append("bus gone")

    class Backend:
        def __init__(self) -> None:
            self._disconnect_monitor_event = asyncio.Event()
            self._bus = Bus()
            self._is_connected = True

        def _cleanup_all(self) -> None:
            done.append("cleaned up")

    class Client:
        def __init__(self, backend) -> None:
            self._backend = backend
            self.is_connected = True

        async def stop_notify(self, uuid: str) -> None:
            done.append("notifications off")

        async def disconnect(self) -> None:
            done.append("DISCONNECTED")

    backend = Backend()
    monitor = backend._disconnect_monitor_event
    assert await helper.release(Client(backend)) is True
    # Everything bleak's own disconnect does, except telling BlueZ to drop
    # the link, which would stop the keyboard typing.
    assert done == ["notifications off", "cleaned up", "bus closed", "bus gone"]
    assert monitor.is_set() and backend._bus is None and backend._is_connected is False

    # A bleak that has changed underneath: not done, said so, and still no
    # disconnect.
    done.clear()
    assert await helper.release(Client(object())) is False
    assert "DISCONNECTED" not in done

    if sys.platform.startswith("linux"):
        from bleak import BleakClient

        # A real client that never connected has nothing to let go of.
        details = {"path": "/org/bluez/hci0/dev_C8_D1_D8_BD_10_0A", "props": {"Alias": "M0110"}}
        client = BleakClient(helper.ble_device("C8:D1:D8:BD:10:0A", "M0110", details))
        assert await helper.release(client) is True
        for name in ("_disconnect_monitor_event", "_cleanup_all", "_bus", "_is_connected"):
            assert hasattr(client._backend, name), name
        print("  bleak's BlueZ client still has what letting go relies on")


async def test_nothing_ends_the_helper() -> None:
    from bleak.exc import BleakError

    endpoint = Endpoint(addresses=lambda: ["127.0.0.1"])

    # The session behind the link goes, as it does on Windows a moment
    # before the link is seen to have dropped, and then the link itself.
    keyboard = FakeKeyboard()
    board = FakeClipboard()
    client = keyboard.attach(0)
    running = asyncio.ensure_future(helper.session(client, board, "M0110", endpoint))
    await until(lambda: keyboard.frames(0, HELLO))
    await asyncio.sleep(0.05)
    client.broken = True
    board.copy(Clip("x" * 3000))
    await until(lambda: keyboard.frames(0, DATA))
    # With no session to ask, frames fall back to the size every link takes.
    assert all(len(frame) <= 20 for frame in keyboard.frames(0, DATA))
    client.is_connected = False
    await asyncio.wait_for(running, 3)

    # Frames with nothing in them, cut short, or of no known kind.
    keyboard = FakeKeyboard()
    client = keyboard.attach(0)
    running = asyncio.ensure_future(helper.session(client, FakeClipboard(), "M0110", endpoint))
    await until(lambda: keyboard.frames(0, HELLO))
    for odd in (b"", bytes([BEGIN]), bytes([DATA]), bytes([RELAY]), bytes([STATUS]), bytes([RESULT]), bytes([0xEE, 1, 2])):
        client.callback(None, bytearray(odd))
    await asyncio.sleep(0.1)
    assert not running.done()
    client.is_connected = False
    await asyncio.wait_for(running, 3)

    # Whatever a frame does to the code that handles it, the session ends
    # quietly, having said goodbye if it still could.
    async def explodes(_bridge, _frame: bytes) -> None:
        raise UnicodeEncodeError("utf-8", "\ud800", 0, 1, "surrogates not allowed")

    keyboard = FakeKeyboard()
    client = keyboard.attach(0)
    handle = Bridge.handle
    Bridge.handle = explodes
    try:
        await asyncio.wait_for(helper.session(client, FakeClipboard(), "M0110", endpoint), 3)
    finally:
        Bridge.handle = handle
    assert keyboard.frames(0, BYE)

    # A write that fails because the link has gone ends the session the same way.
    keyboard = FakeKeyboard()
    client = keyboard.attach(0)
    board = FakeClipboard()
    running = asyncio.ensure_future(helper.session(client, board, "M0110", endpoint))
    await until(lambda: keyboard.frames(0, HELLO))
    await asyncio.sleep(0.05)
    client.is_connected = False
    board.copy(Clip("into the void"))
    await asyncio.wait_for(running, 3)

    # And whatever ends an attempt at a session, another follows.
    attempts = []
    failures = (
        AssertionError(),
        IndexError("empty"),
        UnicodeEncodeError("utf-8", "x", 0, 1, "no"),
        BleakError("gone"),
        OSError(),
        asyncio.TimeoutError(),
    )

    async def once(args, clipboard, endpoint, state) -> None:
        attempts.append(len(attempts))
        raise failures[len(attempts) % len(failures)]

    retry = helper.RETRY_SECONDS
    helper.RETRY_SECONDS = 0.01
    try:
        serving = asyncio.ensure_future(helper.serve(None, None, endpoint, {}, once))
        await until(lambda: len(attempts) >= 2 * len(failures))
        assert not serving.done()
        serving.cancel()
        await asyncio.wait([serving])
        assert serving.cancelled()
    finally:
        helper.RETRY_SECONDS = retry


async def test_joining_and_leaving() -> None:
    """What `attempt` does around a session, with bleak's client played by a stand-in."""
    released = []

    async def release(client) -> bool:
        released.append((client, client.joined, asyncio.get_running_loop().time()))
        return True

    class Joining:
        def __init__(self, device, **options) -> None:
            self.device = device
            self.options = options
            self.joined = False
            self.is_connected = True
            self.has_service = True
            self.takes = 0.0
            self.fails = None
            self.services = self
            made.append(self)

        async def connect(self) -> None:
            await asyncio.sleep(self.takes)
            if self.fails:
                raise self.fails
            self.joined = True

        def get_service(self, _uuid):
            return object() if self.has_service else None

    made: list[Joining] = []
    device = helper.ble_device("C8:D1:D8:BD:10:0A", "M0110", None)
    looked = []

    async def find(name: str, address):
        looked.append((name, address))
        return device

    args = argparse.Namespace(name="M0110", address=None)
    real_release, real_session = helper.release, helper.session
    wait = helper.UNSUPPORTED_SECONDS
    helper.release, helper.UNSUPPORTED_SECONDS = release, 0.3
    sessions = []

    async def session(client, clipboard, name, endpoint) -> None:
        sessions.append(client)

    helper.session = session
    try:
        # It is the device that is handed over, never the bare address.
        await helper.attempt(args, None, None, {}, find, Joining)
        assert made[-1].device is device and looked == [("M0110", None)]
        assert sessions == [made[-1]] and released[-1][:2] == (made[-1], True)

        # Nothing found: nothing joined, nothing to let go of.
        async def nothing(name: str, address):
            return None

        before = len(made)
        await helper.attempt(args, None, None, {}, nothing, Joining)
        assert len(made) == before

        # Firmware without the service: let go of at once, not after the wait.
        def without(device, **options):
            client = Joining(device, **options)
            client.has_service = False
            return client

        started = asyncio.get_running_loop().time()
        await helper.attempt(args, None, None, {}, find, without)
        assert released[-1][0] is made[-1] and released[-1][2] - started < 0.2
        assert asyncio.get_running_loop().time() - started >= 0.3 and len(sessions) == 1

        # A join that fails is still let go of, and the failure is passed on
        # for the loop around it to log.
        def failing(device, **options):
            client = Joining(device, **options)
            client.fails = OSError("no")
            return client

        try:
            await helper.attempt(args, None, None, {}, find, failing)
            assert False, "the failure was swallowed"
        except OSError:
            pass
        assert released[-1][:2] == (made[-1], False)

        # Told to stop in the middle of joining: the join is left to finish,
        # since bleak cancelled part way would disconnect the keyboard, and
        # only then is the link let go of.
        def slow(device, **options):
            client = Joining(device, **options)
            client.takes = 0.3
            return client

        stopping = asyncio.ensure_future(helper.attempt(args, None, None, {}, find, slow))
        await asyncio.sleep(0.1)
        stopping.cancel()
        await asyncio.wait([stopping])
        assert stopping.cancelled()
        assert released[-1][:2] == (made[-1], True) and len(sessions) == 1
    finally:
        helper.release, helper.session, helper.UNSUPPORTED_SECONDS = real_release, real_session, wait


# ---- Against the other implementation ----


async def interop(arguments: list[str]) -> None:
    mode = arguments[0]
    endpoint = Endpoint()

    if mode == "interop-serve":
        with open(arguments[2], "rb") as file:
            content = file.read()
        await endpoint.start()
        endpoint.offering = Offering(int(arguments[1]), lambda: content)
        print(endpoint.port, endpoint.offering.ticket.hex(), endpoint.offering.key.hex(), flush=True)
        await asyncio.Event().wait()

    elif mode == "interop-get":
        offer = Offer(0, bytes.fromhex(arguments[3]), bytes.fromhex(arguments[4]), int(arguments[2]), [arguments[1]])
        content = await endpoint.get(offer)
        if content is None:
            sys.exit("could not fetch it")
        print("-", hashlib.sha256(content).hexdigest(), len(content), flush=True)

    elif mode == "interop-accept":
        await endpoint.start()
        brought: asyncio.Queue[bytes] = asyncio.Queue()
        endpoint.awaiting = (bytes.fromhex(arguments[1]), bytes.fromhex(arguments[2]), brought.put_nowait)
        print(endpoint.port, flush=True)
        content = await brought.get()
        print(hashlib.sha256(content).hexdigest(), len(content), flush=True)
        # Long enough for the byte that says it was taken to be on its way.
        await asyncio.sleep(0.2)

    elif mode == "interop-put":
        with open(arguments[5], "rb") as file:
            content = file.read()
        offering = Offering(0, lambda: content, bytes.fromhex(arguments[3]), bytes.fromhex(arguments[4]))
        if not await endpoint.put([arguments[1]], int(arguments[2]), offering):
            sys.exit("it was not taken")
        print("taken", flush=True)

    else:
        sys.exit(__doc__)


TESTS = [
    test_vectors,
    test_messages,
    test_assembler,
    test_images,
    test_addresses,
    test_stream,
    test_network,
    test_taken_or_not,
    test_connecting,
    test_text_still_goes_through_the_keyboard,
    test_hello,
    test_a_narrow_link,
    test_fetched_over_the_network,
    test_a_long_download,
    test_holds_run_through_a_slow_clipboard,
    test_brought_when_it_cannot_be_fetched,
    test_through_the_keyboard,
    test_one_answer_at_a_time,
    test_gives_up_when_it_cannot_be_had,
    test_nothing_comes,
    test_local_copy_abandons_the_fetch,
    test_an_inline_no_longer_wanted,
    test_a_newer_clip_replaces_the_fetch,
    test_opaque_clips_out_of_the_blue,
    test_a_newer_copy_overtakes_one_being_sent,
    test_older_firmware_carries_text_only,
    test_the_same_thing_is_not_sent_twice,
    test_linux_clipboard,
    test_finding_the_keyboard,
    test_letting_go,
    test_joining_and_leaving,
    test_nothing_ends_the_helper,
]


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1].startswith("interop-"):
        asyncio.run(interop(sys.argv[1:]))
        return

    parser = argparse.ArgumentParser()
    parser.add_argument("only", nargs="*", help="names of the tests to run; all of them if none")
    wanted = parser.parse_args().only

    # Everything that only waits is made to wait less.
    helper.POLL_SECONDS = 0.02
    helper.POKE_SECONDS = 0.01
    helper.HOLD_SECONDS = 0.05
    helper.HELLO_SECONDS = 0.15
    helper.CONNECT_SECONDS = 0.3
    helper.PUT_WAIT_SECONDS = 0.3
    helper.INLINE_WAIT_SECONDS = 15

    ran = 0
    for test in TESTS:
        if wanted and test.__name__ not in wanted:
            continue
        print(test.__name__, flush=True)
        if asyncio.iscoroutinefunction(test):
            asyncio.run(test())
        else:
            test()
        ran += 1
    print(f"helper: ok ({ran} tests)")


if __name__ == "__main__":
    main()
