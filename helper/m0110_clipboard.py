#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["bleak>=1.0", "cryptography>=41", "pillow>=9.1"]
# ///
"""Clipboard helper for the M0110 converter, for Windows and Linux.

The keyboard carries what was copied on one paired computer to the next one it
is switched to, but it cannot read a clipboard, so the computer that is copied
from has to hand it over. On a Mac the M0110HUD app does that. This script is
the same thing for Windows and Linux: it watches the clipboard, writes each
new text clip to the keyboard's clipboard service, and puts clips the keyboard
is carrying from another computer onto this one's clipboard.

An image, or text longer than the keyboard holds, does not go through the
keyboard. The keyboard carries a short message to the helper on the other
computer saying where to fetch it, and the two helpers pass it between
themselves over the network. Only when they cannot reach each other does the
content itself come through the keyboard, cut down to fit.

A computer that is only ever pasted into does not need this script for text:
with no helper there, the keyboard types the clip out instead. An image can
only arrive where a helper is running.

    uv run m0110_clipboard.py            # or: pip install bleak cryptography pillow
    uv run m0110_clipboard.py --verbose

The keyboard must already be paired with this computer. The frames exchanged
with the keyboard are the ones in the firmware's config/clipboard/clip_proto.h;
what the helpers say to each other is in PROTOCOL.md next to this file.
"""

from __future__ import annotations

import argparse
import asyncio
import atexit
import glob
import hashlib
import io
import ipaddress
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import zlib

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

SERVICE_UUID = "b02961de-eec8-443b-9ede-2919a6354188"
RX_UUID = "b02961df-eec8-443b-9ede-2919a6354188"
TX_UUID = "b02961e0-eec8-443b-9ede-2919a6354188"

VERSION = 2
BEGIN, DATA, END, CLEAR, HELLO, ACK, BYE = 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07
RELAY, HOLD = 0x08, 0x09
STATUS, RESULT, POKE = 0x10, 0x11, 0x12
USB_KNOWN, USB_LOCAL, OPAQUE = 0x01, 0x02, 0x04
HOLD_SOON, HOLD_OFF = 0x01, 0x02
UNREACHABLE = 3
# The longest RELAY frame the keyboard passes on, type byte included.
RELAY_MAX = 64

# What the helpers say to each other; see PROTOCOL.md.
KIND_TEXT, KIND_PNG, KIND_JPEG = 1, 2, 3
OFFER, INLINE = 0x01, 0x02
WANT, GONE, CANCEL = 0x01, 0x02, 0x03
GET, PUT = 1, 2
MAGIC = b"M0CB\x01"
# What the receiver of a stream sends back once it has opened the final record.
TAKEN = b"\x01"
RECORD_MAX = 65536
TAG_LENGTH = 16
MAX_ADDRESSES = 6
# The least a keyboard must hold for an OFFER with every address to fit.
MIN_OPAQUE = 256
# A bound on what a misbehaving peer can make this script buffer.
MAX_CONTENT = 256 * 1024 * 1024
# The most an INLINE may come to, whatever the keyboard has room for: beyond
# this the wait for it to trickle through stops being worth it.
INLINE_BUDGET = 40000

# ZMK's default USB IDs, which this firmware keeps.
USB_VENDOR, USB_PRODUCT = "1d50", "615e"

POLL_SECONDS = 0.4
# After the keyboard says a copy shortcut was just pressed: how often, and how
# many times, to look at the clipboard before going back to the slow poll.
POKE_SECONDS = 0.05
POKE_LOOKS = 6
HELLO_SECONDS = 30
RETRY_SECONDS = 5
# How long firmware with no clipboard service is left alone before another look.
UNSUPPORTED_SECONDS = 60
CONNECT_SECONDS = 1.0
PUT_WAIT_SECONDS = 1.5
INLINE_WAIT_SECONDS = 90
HOLD_SECONDS = 0.4
# How long a helper that has connected gets to say what for.
HELLO_WAIT_SECONDS = 5
# How long a stream may make no progress, in either direction, before it is
# given up on.
IDLE_SECONDS = 10
# How long a delivery may go without another frame before it is taken to have
# been abandoned.
DELIVERY_IDLE_SECONDS = 3
# How often an image on a clipboard with no change counter is read again to
# see whether it is still the same one.
IMAGE_POLL_SECONDS = 2.0
# A bound on what a misbehaving peripheral can make this script buffer.
MAX_INCOMING = 65535

verbose = False


def log(message: str) -> None:
    if verbose:
        print(f"clipboard: {message}", flush=True)


last_said = ""


def log_once(message: str) -> None:
    """Logs a line unless it repeats the last one said this way.

    A condition that holds across many tries is reported when it starts
    rather than every time.
    """
    global last_said
    if message != last_said:
        last_said = message
        log(message)


def describe(error: BaseException) -> str:
    return f"{type(error).__name__}: {error}" if str(error) else type(error).__name__


def text_bytes(text: str) -> bytes:
    """Text as it is carried: UTF-8 with LF line endings.

    What comes off a Windows clipboard can hold half of a surrogate pair,
    which has no UTF-8 form; it goes as a question mark rather than raising.
    """
    return text.replace("\r\n", "\n").encode("utf-8", errors="replace")


# ---- Wire format ----


def transfer(payload: bytes, flags: int, frame_cap: int) -> list[bytes]:
    """Every frame needed to send `payload` over a link taking `frame_cap` bytes a write."""
    crc = zlib.crc32(payload)
    frames = [bytes([BEGIN, flags]) + len(payload).to_bytes(2, "little") + crc.to_bytes(4, "little")]
    room = max(1, frame_cap - 3)
    for offset in range(0, len(payload), room):
        frames.append(bytes([DATA]) + offset.to_bytes(2, "little") + payload[offset : offset + room])
    frames.append(bytes([END]))
    return frames


class Assembler:
    """Reassembles a clip the keyboard is delivering.

    DATA must arrive in order. A gap, an overrun or a checksum mismatch fails
    the whole clip at END rather than yielding part of one.
    """

    def __init__(self) -> None:
        self.active = False
        self.poisoned = False
        self.expected = 0
        self.crc = 0
        self.flags = 0
        self.data = bytearray()

    def begin(self, frame: bytes) -> None:
        self.active = False
        if len(frame) < 8:
            return
        length = int.from_bytes(frame[2:4], "little")
        if not 0 < length <= MAX_INCOMING:
            return
        self.flags = frame[1]
        self.expected = length
        self.crc = int.from_bytes(frame[4:8], "little")
        self.data = bytearray()
        self.poisoned = False
        self.active = True

    def feed(self, frame: bytes) -> None:
        if not self.active or len(frame) < 3:
            return
        offset = int.from_bytes(frame[1:3], "little")
        payload = frame[3:]
        if offset != len(self.data) or len(payload) > self.expected - len(self.data):
            self.poisoned = True
            return
        self.data += payload

    def end(self) -> tuple[bytes, int, int] | None:
        """The verified clip, its checksum and its BEGIN flags, or None."""
        ok = (
            self.active
            and not self.poisoned
            and len(self.data) == self.expected
            and zlib.crc32(bytes(self.data)) == self.crc
        )
        result = (bytes(self.data), self.crc, self.flags) if ok else None
        self.active = False
        self.data = bytearray()
        return result


# ---- What the helpers say to each other ----


def pack_addresses(addresses: list[str], room: int) -> bytes:
    """`count { family addr }*` for as many of `addresses` as fit in `room` bytes."""
    packed = b""
    count = 0
    for address in addresses:
        raw = ipaddress.ip_address(address).packed
        entry = bytes([4 if len(raw) == 4 else 6]) + raw
        if count == MAX_ADDRESSES or 1 + len(packed) + len(entry) > room:
            break
        packed += entry
        count += 1
    return bytes([count]) + packed


def unpack_addresses(data: bytes) -> list[str] | None:
    if not data:
        return None
    addresses = []
    position = 1
    for _ in range(data[0]):
        size = {4: 4, 6: 16}.get(data[position] if position < len(data) else 0)
        if size is None or position + 1 + size > len(data):
            return None
        addresses.append(ipaddress.ip_address(data[position + 1 : position + 1 + size]).compressed)
        position += 1 + size
    return addresses


class Offer:
    """Where to fetch a copy that does not fit through the keyboard."""

    def __init__(self, kind: int, ticket: bytes, key: bytes, port: int, addresses: list[str]) -> None:
        self.kind = kind
        self.ticket = ticket
        self.key = key
        self.port = port
        self.addresses = addresses

    def encode(self, room: int = MAX_INCOMING) -> bytes | None:
        """The OFFER, with as many addresses as fit in `room` bytes, or None if it cannot."""
        head = bytes([OFFER, self.kind]) + self.ticket + self.key + self.port.to_bytes(2, "little")
        if len(head) + 1 > room:
            return None
        return head + pack_addresses(self.addresses, room - len(head))

    @classmethod
    def parse(cls, payload: bytes) -> Offer | None:
        if len(payload) < 45 or payload[0] != OFFER:
            return None
        addresses = unpack_addresses(payload[44:])
        if addresses is None:
            return None
        port = int.from_bytes(payload[42:44], "little")
        return cls(payload[1], payload[2:10], payload[10:42], port, addresses)


def encode_want(ticket: bytes, port: int, addresses: list[str], room: int) -> bytes:
    """A WANT with as many addresses as fit in `room` bytes."""
    head = bytes([WANT]) + ticket + port.to_bytes(2, "little")
    return head + pack_addresses(addresses, room - len(head))


def parse_want(payload: bytes) -> tuple[bytes, int, list[str]] | None:
    if len(payload) < 12 or payload[0] != WANT:
        return None
    addresses = unpack_addresses(payload[11:])
    if addresses is None:
        return None
    return payload[1:9], int.from_bytes(payload[9:11], "little"), addresses


def shrink(image: bytes, room: int) -> bytes | None:
    """`image` scaled down and re-encoded as a JPEG of at most `room` bytes."""
    from PIL import Image

    picture = flatten(opened(image))
    for side, quality in (
        (2048, 60),
        (1600, 60),
        (1280, 50),
        (1024, 50),
        (800, 45),
        (640, 40),
        (480, 40),
        (320, 35),
        (240, 30),
        (160, 30),
        (96, 25),
    ):
        smaller = picture.copy()
        smaller.thumbnail((side, side), Image.Resampling.LANCZOS)
        out = io.BytesIO()
        smaller.save(out, "JPEG", quality=quality, optimize=True)
        if out.tell() <= room:
            return out.getvalue()
    return None


def encode_inline(kind: int, ticket: bytes, content: bytes, room: int) -> bytes | None:
    """The content as an INLINE of at most `room` bytes, or None if it cannot be made to fit.

    Text either fits or it does not. An image is scaled down until it does.
    """
    room -= 10
    if len(content) > room:
        if kind == KIND_TEXT:
            return None
        try:
            content = shrink(content, room)
        except Exception:  # Pillow raises a variety of things on a bad image
            content = None
        if content is None:
            return None
        kind = KIND_JPEG
    return bytes([INLINE, kind]) + ticket + content


def parse_inline(payload: bytes) -> tuple[int, bytes, bytes] | None:
    """The kind, the ticket and the content of an INLINE."""
    if len(payload) < 10 or payload[0] != INLINE:
        return None
    return payload[1], payload[2:10], payload[10:]


# ---- Images ----


def opened(image: bytes):
    """Decodes an image the way it is meant to be seen, in a mode every format here can hold.

    A camera says which way up its picture goes in a tag, not in the pixels,
    and the tag is lost when the picture is encoded again. Sixteen-bit grey
    has to be scaled down to eight, since converting it clips instead and
    everything comes out white. CMYK and the like have no place in a PNG.
    """
    from PIL import Image, ImageOps

    picture = Image.open(io.BytesIO(image))
    picture = ImageOps.exif_transpose(picture) or picture
    if picture.mode == "I" or picture.mode.startswith("I;16"):
        picture = picture.convert("I").point(lambda value: value * (1 / 256)).convert("L")
    elif picture.mode not in ("1", "L", "LA", "P", "RGB", "RGBA"):
        picture = picture.convert("RGB")
    return picture


def flatten(picture):
    """`picture` as plain RGB, with anything transparent put on white."""
    from PIL import Image

    if picture.mode in ("RGBA", "LA") or "transparency" in picture.info:
        layer = picture.convert("RGBA")
        picture = Image.new("RGB", layer.size, (255, 255, 255))
        picture.paste(layer, mask=layer.split()[3])
    return picture.convert("RGB")


def to_png(kind: int, image: bytes) -> bytes:
    """The image as a PNG, which is what every clipboard takes."""
    if kind == KIND_PNG:
        # Passed on as it is, once it has been seen to be one at all.
        if not image.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("not a PNG")
        return image

    out = io.BytesIO()
    opened(image).save(out, "PNG")
    return out.getvalue()


def dib_to_png(dib: bytes) -> bytes:
    """A Windows device-independent bitmap, as found on its clipboard, as a PNG."""
    from PIL import BmpImagePlugin

    out = io.BytesIO()
    BmpImagePlugin.DibImageFile(io.BytesIO(dib)).save(out, "PNG")
    return out.getvalue()


def png_to_dib(png: bytes) -> bytes:
    """The other way: a BMP file is a 14-byte file header and then the bitmap."""
    out = io.BytesIO()
    flatten(opened(png)).save(out, "BMP")
    return out.getvalue()[14:]


def trim_png(data: bytes) -> bytes:
    """Cuts off what follows the PNG's last chunk; clipboard memory is rounded up in size."""
    end = data.rfind(b"IEND")
    return data[: end + 8] if end >= 0 else data


# ---- The stream between two helpers ----


class TransferError(Exception):
    """A stream that ended early, stalled, did not open, or ran past any sensible size."""


def hello(role: int, ticket: bytes) -> bytes:
    return MAGIC + bytes([role]) + ticket


def seal(key: bytes, ticket: bytes, content: bytes):
    """Yields `content` as the records of a stream."""
    cipher = ChaCha20Poly1305(key)
    count = max(1, -(-len(content) // RECORD_MAX))
    for number in range(count):
        last = 1 if number == count - 1 else 0
        nonce = bytes(4) + number.to_bytes(8, "little")
        chunk = content[number * RECORD_MAX : (number + 1) * RECORD_MAX]
        sealed = cipher.encrypt(nonce, chunk, ticket + bytes([last]))
        yield bytes([last]) + len(sealed).to_bytes(4, "little") + sealed


async def read_exactly(reader: asyncio.StreamReader, count: int) -> bytes:
    """Reads `count` bytes, giving up if none at all arrive for a while.

    The wait is on each piece, not on the whole: a large transfer that keeps
    moving may take as long as it takes.
    """
    data = bytearray()
    while len(data) < count:
        piece = await asyncio.wait_for(reader.read(count - len(data)), IDLE_SECONDS)
        if not piece:
            raise asyncio.IncompleteReadError(bytes(data), count)
        data += piece
    return bytes(data)


async def read_content(reader: asyncio.StreamReader, writer, key: bytes, ticket: bytes) -> bytes:
    """Reads a stream to its final record, says so to the sender, and returns what it sealed."""
    cipher = ChaCha20Poly1305(key)
    content = bytearray()
    number = 0
    try:
        while True:
            head = await read_exactly(reader, 5)
            last = head[0]
            size = int.from_bytes(head[1:5], "little")
            if last > 1 or not TAG_LENGTH <= size <= RECORD_MAX + TAG_LENGTH:
                raise TransferError("malformed record")
            if len(content) + size - TAG_LENGTH > MAX_CONTENT:
                raise TransferError("too much content")
            sealed = await read_exactly(reader, size)
            nonce = bytes(4) + number.to_bytes(8, "little")
            content += cipher.decrypt(nonce, sealed, ticket + bytes([last]))
            if last:
                break
            number += 1
    except InvalidTag:
        raise TransferError("a record did not open") from None
    except (asyncio.IncompleteReadError, asyncio.TimeoutError, OSError):
        raise TransferError("the stream stalled or ended before its final record") from None

    # Until it hears this the sender does not count the content as taken. A
    # connection that merely closes tells it nothing.
    if writer is not None:
        try:
            writer.write(TAKEN)
            await asyncio.wait_for(writer.drain(), IDLE_SECONDS)
        except (asyncio.TimeoutError, OSError):
            pass
    return bytes(content)


async def write_content(reader, writer, key: bytes, ticket: bytes, content: bytes) -> bool:
    """Writes `content` as a stream. True only if the far end says it took all of it."""
    try:
        # Whether the stream is moving is judged by whether there is room to
        # write more. A small buffer underneath keeps that honest: with a
        # large one, megabytes can sit unsent while everything looks done.
        link = writer.get_extra_info("socket")
        if link is not None:
            link.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, RECORD_MAX)
        for record in seal(key, ticket, content):
            writer.write(record)
            # Returns at once while the far end keeps reading, and not at
            # all if it has stopped.
            await asyncio.wait_for(writer.drain(), IDLE_SECONDS)
        return await asyncio.wait_for(reader.read(1), IDLE_SECONDS) == TAKEN
    except (asyncio.TimeoutError, OSError):
        return False


def close(writer) -> None:
    try:
        writer.close()
    except OSError:
        pass


def usable(addresses: list[str]) -> list[str]:
    """Drops addresses another computer could not connect to, and puts IPv4 first."""
    kept: list[str] = []
    for address in addresses:
        try:
            parsed = ipaddress.ip_address(address.split("%")[0])
        except ValueError:
            continue
        if parsed.is_loopback or parsed.is_link_local or parsed.is_unspecified or parsed.is_multicast:
            continue
        if parsed.compressed not in kept:
            kept.append(parsed.compressed)
    kept.sort(key=lambda address: ":" in address)
    return kept[:MAX_ADDRESSES]


def routed_addresses() -> list[str]:
    """This computer's addresses on the interfaces its routes lead out of.

    Connecting a UDP socket sends nothing. It only makes the system choose
    the address it would send from.
    """
    probes = [(socket.AF_INET, target) for target in ("192.168.255.254", "172.31.255.254", "10.255.255.254", "8.8.8.8")]
    probes.append((socket.AF_INET6, "2001:4860:4860::8888"))
    found = []
    for family, target in probes:
        try:
            with socket.socket(family, socket.SOCK_DGRAM) as probe:
                probe.connect((target, 9))
                found.append(probe.getsockname()[0])
        except OSError:
            continue
    return found


def parse_interfaces(listing: str) -> list[str]:
    """The addresses in the output of `ip -j addr`, on every interface that is up."""
    found = []
    for link in json.loads(listing):
        flags = link.get("flags", [])
        if "UP" not in flags or "LOOPBACK" in flags:
            continue
        for entry in link.get("addr_info", []):
            if entry.get("family") in ("inet", "inet6") and entry.get("local"):
                found.append(entry["local"])
    return found


def interface_addresses() -> list[str] | None:
    """Every interface's addresses, where there is an `ip` to ask; None where not."""
    if not shutil.which("ip"):
        return None
    try:
        done = subprocess.run(["ip", "-j", "addr"], capture_output=True, text=True, timeout=2)
        return parse_interfaces(done.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError, AttributeError, TypeError):
        return None


def local_addresses() -> list[str]:
    """This computer's own addresses, as far as they can be found without asking for more software.

    The one the default route leaves by comes first, as the likeliest to be
    reached. Then every interface's: from `ip` on Linux, and from the host
    name on Windows, where that gives them all. On Linux the host name often
    gives only a loopback address, so it is the last resort there.
    """
    found = routed_addresses()
    listed = interface_addresses()
    if listed is None:
        try:
            listed = [info[4][0] for info in socket.getaddrinfo(socket.gethostname(), None)]
        except OSError:
            listed = []
    return usable(found + listed)


def listening_socket() -> socket.socket:
    """One socket on one port for both IPv4 and IPv6 where the system can, IPv4 alone where not."""
    if socket.has_dualstack_ipv6():
        try:
            return socket.create_server(("", 0), family=socket.AF_INET6, dualstack_ipv6=True)
        except OSError:
            pass
    return socket.create_server(("", 0))


class Offering:
    """The latest copy made here, on offer to the other computers.

    The content is produced when first asked for, off the event loop, since
    turning a large bitmap into a PNG takes a moment the OFFER should not wait
    for.
    """

    def __init__(self, kind: int, produce, ticket: bytes | None = None, key: bytes | None = None) -> None:
        self.kind = kind
        self.ticket = ticket or os.urandom(8)
        self.key = key or os.urandom(32)
        self.produce = produce
        self.made: bytes | None = None
        self.making = asyncio.Lock()

    async def content(self) -> bytes:
        async with self.making:
            if self.made is None:
                self.made = await asyncio.to_thread(self.produce)
            return self.made


class Endpoint:
    """This helper's end of the network: one listener, and the connections it makes itself.

    `dial` and `addresses` are what tests swap out to stand for a network
    that does not let the two helpers reach each other.
    """

    def __init__(self, dial=None, addresses=None) -> None:
        self.dial = dial or asyncio.open_connection
        self.addresses = addresses or local_addresses
        self.port = 0
        self.server = None
        self.offering: Offering | None = None
        # A copy this helper has asked to be sent: its id, its key, and what
        # to call with the content.
        self.awaiting: tuple[bytes, bytes, object] | None = None

    async def start(self) -> None:
        listener = listening_socket()
        self.server = await asyncio.start_server(self.accept, sock=listener)
        self.port = listener.getsockname()[1]

    async def stop(self) -> None:
        if self.server:
            self.server.close()
            await self.server.wait_closed()
            self.server = None
            self.port = 0

    async def accept(self, reader, writer) -> None:
        """Serves one connection: a GET for the copy on offer, or a PUT of one asked for."""
        try:
            opening = await asyncio.wait_for(reader.readexactly(len(MAGIC) + 9), HELLO_WAIT_SECONDS)
            role, ticket = opening[len(MAGIC)], opening[len(MAGIC) + 1 :]
            if opening[: len(MAGIC)] != MAGIC:
                return
            if role == GET:
                offering = self.offering
                if offering and offering.ticket == ticket:
                    await write_content(reader, writer, offering.key, ticket, await offering.content())
            elif role == PUT:
                awaiting = self.awaiting
                if awaiting and awaiting[0] == ticket:
                    content = await read_content(reader, writer, awaiting[1], ticket)
                    # Still the copy being waited for, and nobody else got
                    # there first.
                    if self.awaiting is awaiting:
                        awaiting[2](content)
        except (TransferError, asyncio.IncompleteReadError, asyncio.TimeoutError, OSError):
            pass
        except Exception as error:  # producing the content can fail in its own ways
            log(f"could not serve a copy ({describe(error)})")
        finally:
            close(writer)

    async def connect(self, addresses: list[str], port: int):
        """Connects to every address at once and keeps the first that answers in time."""
        attempts = [asyncio.ensure_future(self.dial(address, port)) for address in addresses]
        loop = asyncio.get_running_loop()
        deadline = loop.time() + CONNECT_SECONDS
        pending = set(attempts)
        winner = None

        def discard(attempt) -> None:
            if not attempt.cancelled() and attempt.exception() is None and attempt.result() is not winner:
                close(attempt.result()[1])

        try:
            while pending and winner is None and loop.time() < deadline:
                done, pending = await asyncio.wait(
                    pending, timeout=deadline - loop.time(), return_when=asyncio.FIRST_COMPLETED
                )
                for attempt in done:
                    if winner is None and not attempt.cancelled() and attempt.exception() is None:
                        winner = attempt.result()
            return winner
        finally:
            # Whether one won, time ran out, or this was itself cancelled
            # part way: none of the others is left to dangle.
            for attempt in attempts:
                attempt.add_done_callback(discard)
                attempt.cancel()

    async def get(self, offer: Offer) -> bytes | None:
        """Fetches the copy `offer` names from the helper that made it."""
        link = await self.connect(offer.addresses, offer.port)
        if link is None:
            return None
        reader, writer = link
        try:
            writer.write(hello(GET, offer.ticket))
            return await read_content(reader, writer, offer.key, offer.ticket)
        except (TransferError, OSError):
            return None
        finally:
            close(writer)

    async def put(self, addresses: list[str], port: int, offering: Offering) -> bool:
        """Takes the copy on offer to a helper that could not come for it.

        True only if that helper said it took all of it.
        """
        content = await offering.content()
        link = await self.connect(addresses, port)
        if link is None:
            return False
        reader, writer = link
        try:
            writer.write(hello(PUT, offering.ticket))
            return await write_content(reader, writer, offering.key, offering.ticket, content)
        finally:
            close(writer)


# ---- This computer's clipboard ----


class Clip:
    """What is on the clipboard: text or an image, and whether it must not be carried.

    `form` says what the image bytes are: "png", "jpeg", or "dib" for a
    Windows bitmap that has yet to be turned into a PNG. `owner` is who put
    it there, where the system can say, and `after` is the clipboard's
    change marker as it stood once the reading was done, where reading can
    itself move it.
    """

    def __init__(
        self,
        text: str | None,
        private: bool = False,
        image: bytes | None = None,
        form: str = "",
        owner: object = None,
        after: object = None,
    ) -> None:
        self.text = text
        self.private = private
        self.image = image
        self.form = form
        self.owner = owner
        self.after = after

    def kind(self) -> int:
        return KIND_JPEG if self.form == "jpeg" else KIND_PNG

    def content(self) -> bytes:
        """The image in the form it is sent in. Slow for a large bitmap."""
        return dib_to_png(self.image) if self.form == "dib" else self.image

    def fingerprint(self) -> bytes:
        """Tells this content from other content, without keeping it."""
        if self.private:
            return b"private"
        if self.text:
            return fingerprint(KIND_TEXT, text_bytes(self.text))
        if self.image:
            return fingerprint(KIND_PNG, self.image)
        return b"nothing"


def fingerprint(kind: int, content: bytes) -> bytes:
    return hashlib.sha256((b"text" if kind == KIND_TEXT else b"image") + content).digest()


class WindowsClipboard:
    """The Win32 clipboard through ctypes."""

    CF_DIB = 8
    CF_UNICODETEXT = 13
    GMEM_MOVEABLE = 0x0002

    def __init__(self) -> None:
        import ctypes
        from ctypes import wintypes

        self.ctypes = ctypes
        user32 = self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        kernel32 = self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

        def declare(function, result, *arguments) -> None:
            # Handles are pointer-sized; left undeclared, ctypes would pass
            # and return them as int and cut them short.
            function.restype = result
            function.argtypes = list(arguments)

        declare(user32.OpenClipboard, wintypes.BOOL, wintypes.HWND)
        declare(user32.CloseClipboard, wintypes.BOOL)
        declare(user32.EmptyClipboard, wintypes.BOOL)
        declare(user32.GetClipboardData, wintypes.HANDLE, wintypes.UINT)
        declare(user32.SetClipboardData, wintypes.HANDLE, wintypes.UINT, wintypes.HANDLE)
        declare(user32.IsClipboardFormatAvailable, wintypes.BOOL, wintypes.UINT)
        declare(user32.RegisterClipboardFormatW, wintypes.UINT, wintypes.LPCWSTR)
        declare(user32.GetClipboardSequenceNumber, wintypes.DWORD)
        declare(user32.GetClipboardOwner, wintypes.HWND)
        declare(
            user32.CreateWindowExW,
            wintypes.HWND,
            wintypes.DWORD,
            wintypes.LPCWSTR,
            wintypes.LPCWSTR,
            wintypes.DWORD,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            wintypes.HWND,
            wintypes.HMENU,
            wintypes.HINSTANCE,
            wintypes.LPVOID,
        )
        declare(user32.DestroyWindow, wintypes.BOOL, wintypes.HWND)
        declare(kernel32.GlobalAlloc, wintypes.HGLOBAL, wintypes.UINT, ctypes.c_size_t)
        declare(kernel32.GlobalLock, wintypes.LPVOID, wintypes.HGLOBAL)
        declare(kernel32.GlobalUnlock, wintypes.BOOL, wintypes.HGLOBAL)
        declare(kernel32.GlobalFree, wintypes.HGLOBAL, wintypes.HGLOBAL)
        declare(kernel32.GlobalSize, ctypes.c_size_t, wintypes.HGLOBAL)
        declare(kernel32.Sleep, None, wintypes.DWORD)

        # How a password manager says "keep this out of clipboard history and
        # cloud sync". The same wish applies to a keyboard. Some set the
        # first; some only set the other two, to zero.
        self.exclude_format = user32.RegisterClipboardFormatW("ExcludeClipboardContentFromMonitorProcessing")
        self.history_format = user32.RegisterClipboardFormatW("CanIncludeInClipboardHistory")
        self.cloud_format = user32.RegisterClipboardFormatW("CanUploadToCloudClipboard")
        # What browsers and image editors put next to the bitmap, and the
        # only one of the two that keeps transparency.
        self.png_format = user32.RegisterClipboardFormatW("PNG")

    def marker(self, fresh: bool = False) -> object:
        return self.user32.GetClipboardSequenceNumber()

    def _open(self, window, tries: int) -> bool:
        # Another program may hold the clipboard for a moment.
        for _ in range(tries):
            if self.user32.OpenClipboard(window):
                return True
            self.kernel32.Sleep(10)
        return False

    def _bytes(self, kind: int) -> bytes | None:
        """What the open clipboard holds in one format."""
        if not kind or not self.user32.IsClipboardFormatAvailable(kind):
            return None
        handle = self.user32.GetClipboardData(kind)
        if not handle:
            return None
        pointer = self.kernel32.GlobalLock(handle)
        if not pointer:
            return None
        try:
            return self.ctypes.string_at(pointer, self.kernel32.GlobalSize(handle))
        finally:
            self.kernel32.GlobalUnlock(handle)

    def _text(self) -> str | None:
        handle = self.user32.GetClipboardData(self.CF_UNICODETEXT)
        pointer = self.kernel32.GlobalLock(handle) if handle else None
        if not pointer:
            return None
        try:
            return self.ctypes.wstring_at(pointer) or None
        finally:
            self.kernel32.GlobalUnlock(handle)

    def _private(self) -> bool:
        if self.exclude_format and self.user32.IsClipboardFormatAvailable(self.exclude_format):
            return True
        for kind in (self.history_format, self.cloud_format):
            value = self._bytes(kind)
            # A DWORD: zero is "no, it may not".
            if value is not None and not any(value[:4]):
                return True
        return False

    def read(self) -> Clip | None:
        """What is on the clipboard, or None if it could not be looked at.

        Not being able to look, because another program has the clipboard
        open, is not the same as there being nothing on it.
        """
        if not self._open(None, 10):
            return None
        try:
            owner = self.user32.GetClipboardOwner() or 0
            if self._private():
                clip = Clip(None, private=True)
            else:
                text = self._text()
                png = None if text else self._bytes(self.png_format)
                # Windows makes this one out of whichever bitmap format was
                # put there, so it covers them all.
                dib = None if text or png else self._bytes(self.CF_DIB)
                if text:
                    clip = Clip(text)
                elif png:
                    clip = Clip(None, image=trim_png(png), form="png")
                elif dib:
                    clip = Clip(None, image=dib, form="dib")
                else:
                    clip = Clip(None)
        finally:
            self.user32.CloseClipboard()

        clip.owner = owner
        # Asking for a format its owner had only promised makes the owner
        # render it, and that moves the number on. Taken again here, so the
        # reading is not mistaken for another copy.
        clip.after = self.user32.GetClipboardSequenceNumber()
        return clip

    def _put(self, kind: int, data: bytes) -> bool:
        """Gives the open clipboard `data` in one format."""
        handle = self.kernel32.GlobalAlloc(self.GMEM_MOVEABLE, len(data))
        if not handle:
            return False
        pointer = self.kernel32.GlobalLock(handle)
        if not pointer:
            self.kernel32.GlobalFree(handle)
            return False
        self.ctypes.memmove(pointer, data, len(data))
        self.kernel32.GlobalUnlock(handle)
        # On success the clipboard owns the memory.
        if not self.user32.SetClipboardData(kind, handle):
            self.kernel32.GlobalFree(handle)
            return False
        return True

    def _write(self, formats: list[tuple[int, bytes]]) -> bool:
        """Replaces what is on the clipboard, most descriptive format first.

        Emptying a clipboard opened with no window leaves it with no owner,
        and setting data then fails. So a window is made to own it, and is
        gone again before this returns: all of it in one call on one thread,
        with never a window left whose messages nobody is reading.
        """
        window = self.user32.CreateWindowExW(0, "STATIC", None, 0, 0, 0, 0, 0, None, None, None, None)
        if not window:
            return False
        try:
            # About a second: a paste is waiting on this.
            if not self._open(window, 100):
                return False
            try:
                if not self.user32.EmptyClipboard():
                    return False
                placed = False
                for kind, data in formats:
                    placed = self._put(kind, data) or placed
                return placed
            finally:
                self.user32.CloseClipboard()
        finally:
            self.user32.DestroyWindow(window)

    def write(self, text: str) -> bool:
        # Windows programs expect CRLF line endings on the clipboard.
        text = re.sub(r"\r?\n", "\r\n", text)
        return self._write([(self.CF_UNICODETEXT, (text + "\0").encode("utf-16-le", errors="replace"))])

    def write_image(self, png: bytes) -> bool:
        try:
            dib = png_to_dib(png)
        except Exception:  # Pillow raises a variety of things on a bad image
            return False
        # The bitmap is what most programs paste. The PNG is for the ones
        # that would otherwise lose the transparency.
        formats = [(self.png_format, png)] if self.png_format else []
        return self._write(formats + [(self.CF_DIB, dib)])


class LinuxClipboard:
    """wl-clipboard on Wayland, xclip or xsel on X11.

    None of them has a change counter to ask for, and how a new copy is
    noticed depends on what the session offers:

    - A Wayland compositor with the data-control protocol: `wl-paste --watch`
      runs alongside and says each time the clipboard changes.
    - X11: the clipboard is looked at on every poll. Text is read each time.
      An image is told apart by the timestamp its owner gives the selection,
      so it is read once per copy; an owner that gives none has its image
      read again every so often instead.
    - A Wayland compositor without data-control, GNOME's among them: every
      look by wl-paste opens a window that takes the focus for a moment. So
      xclip is used through XWayland where it is there, and where it is not,
      the clipboard is only looked at when the keyboard says a copy shortcut
      was pressed.
    """

    # Set by KeePassXC and others on items that should not be recorded.
    PRIVATE_TYPE = "x-kde-passwordManagerHint"
    # In order of preference. The first one the owner offers is asked for.
    TEXT_TYPES = ("text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT")
    IMAGE_TYPES = (("image/png", "png"), ("image/jpeg", "jpeg"))
    NOTHING = hashlib.sha256(b"").digest()

    def __init__(self, environ=None, which=shutil.which) -> None:
        environ = os.environ if environ is None else environ
        self.tool = ""
        # wl-paste is saying when the clipboard changes, and how many times
        # it has.
        self.watching = False
        self.watcher = None
        self.changes = 0
        # Nothing says when it changes, and looking costs too much to do
        # unasked.
        self.poke_only = False
        self.last: object = (False, self.NOTHING)

        # The image last seen and when, for an owner that gives no timestamp.
        self.image_seen: tuple[str, bytes] | None = None
        self.image_read = 0.0
        # An owner whose timestamp keeps moving though its image does not
        # is not to be believed.
        self.stamps_trusted = True
        self.stamp_strikes = 0
        self.read_stamp: bytes | None = None
        self.read_image: bytes | None = None

        wayland = bool(environ.get("WAYLAND_DISPLAY")) and which("wl-paste") and which("wl-copy")
        if wayland and self._watch():
            self.tool = "wl"
            self.watching = True
        elif wayland and which("xclip") and environ.get("DISPLAY"):
            self.tool = "xclip"
            log("this compositor does not let a program watch the clipboard; using xclip through XWayland")
        elif wayland:
            self.tool = "wl"
            self.poke_only = True
            log(
                "this compositor does not let a program watch the clipboard, and there is no xclip: "
                "only what is copied with the keyboard's own copy shortcut will be carried"
            )
        elif which("xclip"):
            self.tool = "xclip"
        elif which("xsel"):
            self.tool = "xsel"
            log("xsel only handles text; install xclip to carry images as well")
        else:
            sys.exit("Install wl-clipboard (Wayland), or xclip or xsel (X11).")

    def _watch(self) -> bool:
        """Starts wl-paste in watch mode. False if this compositor will not have it."""
        try:
            child = subprocess.Popen(
                ["wl-paste", "--watch", "echo"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            return False
        # Without the data-control protocol it says so and exits at once.
        try:
            child.wait(timeout=0.5)
            return False
        except subprocess.TimeoutExpired:
            pass
        self.watcher = child
        # It would otherwise outlive the helper, watching for nobody.
        atexit.register(self.close)
        threading.Thread(target=self._count, args=(child,), daemon=True).start()
        return True

    def close(self) -> None:
        """Stops what was started to watch the clipboard."""
        child, self.watcher = self.watcher, None
        if child is not None and child.poll() is None:
            child.terminate()

    def _count(self, child) -> None:
        for _line in child.stdout:
            self.changes += 1
        # It has gone, with the compositor or without. The clipboard is
        # looked at on every poll from here on.
        self.watching = False

    def _types_command(self) -> list[str] | None:
        if self.tool == "wl":
            return ["wl-paste", "--list-types"]
        if self.tool == "xclip":
            return ["xclip", "-selection", "clipboard", "-o", "-t", "TARGETS"]
        return None

    def _paste_command(self, kind: str) -> list[str]:
        if self.tool == "wl":
            return ["wl-paste", "--no-newline", "--type", kind]
        if self.tool == "xclip":
            return ["xclip", "-selection", "clipboard", "-o", "-t", kind]
        return ["xsel", "--clipboard", "--output"]

    def _copy_command(self, kind: str) -> list[str]:
        if self.tool == "wl":
            return ["wl-copy", "--type", kind]
        if self.tool == "xclip":
            # With no type named xclip serves text under every name a
            # program might ask for it by.
            return ["xclip", "-selection", "clipboard", "-i"] + ([] if kind.startswith("text/") else ["-t", kind])
        return ["xsel", "--clipboard", "--input"]

    def _run(self, command: list[str], timeout: float = 2) -> bytes | None:
        try:
            done = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        return done.stdout if done.returncode == 0 else None

    def _offered(self) -> list[str]:
        """The types the clipboard's owner offers it in."""
        command = self._types_command()
        listing = self._run(command) if command else None
        lines = listing.decode("utf-8", errors="replace").splitlines() if listing else []
        return [line.strip() for line in lines if line.strip()]

    def _text(self, offered: list[str]) -> bytes | None:
        """The clipboard's text, if it holds any.

        Asking is not enough to find out. Some owners, xclip among them,
        answer a request for text with whatever they hold, and an image
        piped to xclip by a screenshot script would be read as text. So where
        the types can be listed, text is asked for only if it is among them,
        and by the first acceptable name the owner gives it.
        """
        if self.tool == "xsel":
            return self._run(self._paste_command("")) or None
        if offered:
            wanted = next((name for name in self.TEXT_TYPES if name in offered), None)
        else:
            # The owner would not say. Ask the usual way, in case.
            wanted = self.TEXT_TYPES[0] if self.tool == "wl" else "UTF8_STRING"
        return (self._run(self._paste_command(wanted)) or None) if wanted else None

    def _image(self, offered: list[str]) -> tuple[bytes, str] | None:
        """The clipboard's image and its form, if it holds one this can read."""
        if self.tool == "xsel":
            return None
        for mime, form in self.IMAGE_TYPES:
            if mime in offered:
                image = self._run(self._paste_command(mime), timeout=10)
                if image:
                    return image, form
        return None

    def _stamp(self, offered: list[str]) -> bytes | None:
        """When the owner took the selection, by its own account.

        An X11 owner that follows the conventions answers TIMESTAMP with the
        time it became the owner, which is new with every copy. Only asked of
        one that lists it: xclip, as an owner, would answer with its content.
        """
        if self.tool != "xclip" or "TIMESTAMP" not in offered or not self.stamps_trusted:
            return None
        return self._run(self._paste_command("TIMESTAMP")) or None

    def read(self) -> Clip:
        offered = self._offered()
        if self.PRIVATE_TYPE in offered:
            return Clip(None, private=True)
        raw = self._text(offered)
        if raw:
            return Clip(raw.decode("utf-8", errors="replace"))
        image = self._image(offered)
        if not image:
            return Clip(None)

        stamp = self._stamp(offered)
        if stamp and self.read_stamp and stamp != self.read_stamp and image[0] == self.read_image:
            # Once is the same image copied again. More than that is a
            # timestamp that means nothing.
            self.stamp_strikes += 1
            if self.stamp_strikes >= 3:
                self.stamps_trusted = False
                log("a program's clipboard timestamp changes by itself; images are read the slow way from now on")
        elif image[0] != self.read_image:
            self.stamp_strikes = 0
        self.read_stamp, self.read_image = stamp, image[0]
        return Clip(None, image=image[0], form=image[1])

    def marker(self, fresh: bool = False) -> object:
        """Stands in for the change counter there is none of.

        `fresh` says a copy shortcut was just pressed, so that it is worth
        looking even where looking is costly.
        """
        if self.watching:
            return ("changes", self.changes)
        if self.poke_only and not fresh:
            return self.last
        self.last = self._look(fresh)
        return self.last

    def _look(self, fresh: bool) -> object:
        """A marker made from the clipboard's content, hashed so that the last clip is not kept around in the clear."""
        offered = self._offered()
        if self.PRIVATE_TYPE in offered:
            return (True, self.NOTHING)
        raw = self._text(offered)
        if raw:
            self.image_seen = None
            return (False, hashlib.sha256(raw).digest())
        if self.tool == "xsel" or not any(mime in offered for mime, _ in self.IMAGE_TYPES):
            self.image_seen = None
            return (False, self.NOTHING)

        listing = " ".join(offered)
        stamp = self._stamp(offered)
        if stamp:
            return ("image", hashlib.sha256(listing.encode() + stamp).digest())

        # Fetching an image makes the program that owns it encode it all
        # over again, so it is not done on every poll.
        stale = time.monotonic() - self.image_read >= IMAGE_POLL_SECONDS
        if fresh or stale or self.image_seen is None or self.image_seen[0] != listing:
            image = self._image(offered)
            self.image_seen = (listing, hashlib.sha256(image[0] if image else b"").digest())
            self.image_read = time.monotonic()
        return ("image", self.image_seen[1])

    def _hand_over(self, command: list[str], data: bytes) -> bool:
        # xclip and wl-copy stay alive to serve the selection and would
        # never return.
        try:
            child = subprocess.Popen(
                command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            child.stdin.write(data)
            child.stdin.close()
            return True
        except OSError:
            return False

    def write(self, text: str) -> bool:
        return self._hand_over(self._copy_command("text/plain;charset=utf-8"), text.encode("utf-8", errors="replace"))

    def write_image(self, png: bytes) -> bool:
        if self.tool == "xsel":
            log("xsel cannot put an image on the clipboard; install xclip")
            return False
        return self._hand_over(self._copy_command("image/png"), png)


def keyboard_on_usb(name: str) -> int:
    """BEGIN flags saying whether the keyboard is also plugged into this computer.

    The firmware cannot tell on its own that its USB port and one of its
    Bluetooth profiles are the same computer. Where this cannot be determined
    the flags say so, and the keyboard then leaves pastes over USB alone.
    """
    if not sys.platform.startswith("linux"):
        return 0
    for device in glob.glob("/sys/bus/usb/devices/*"):
        try:
            with open(f"{device}/idVendor") as vendor, open(f"{device}/idProduct") as product:
                if vendor.read().strip() != USB_VENDOR or product.read().strip() != USB_PRODUCT:
                    continue
            # The IDs are shared by every ZMK keyboard; the name says it is ours.
            with open(f"{device}/product") as label:
                if name.lower() in label.read().lower():
                    return USB_KNOWN | USB_LOCAL
        except OSError:
            continue
    return USB_KNOWN


# ---- Finding the keyboard ----


def find_address(name: str) -> str | None:
    """The Bluetooth address of the paired keyboard called `name`.

    It is connected for HID and not advertising, so it cannot be scanned for;
    the operating system's list of paired devices is asked instead.
    """
    if sys.platform == "win32":
        script = (
            "Get-PnpDevice -Class Bluetooth | "
            f"Where-Object {{ $_.FriendlyName -eq '{name}' }} | "
            "ForEach-Object { $_.InstanceId }"
        )
        command = ["powershell", "-NoProfile", "-Command", script]
        pattern = r"BTHLE\\DEV_([0-9A-F]{12})"
    else:
        command = ["bluetoothctl", "devices"]
        pattern = rf"Device ((?:[0-9A-F]{{2}}:){{5}}[0-9A-F]{{2}}) {re.escape(name)}\s*$"

    try:
        output = subprocess.run(command, capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None

    match = re.search(pattern, output, re.IGNORECASE | re.MULTILINE)
    if not match:
        return None
    address = match.group(1).upper()
    if ":" not in address:
        address = ":".join(address[i : i + 2] for i in range(0, 12, 2))
    return address


DEVICE_INTERFACE = "org.bluez.Device1"


def bluez_device(objects: dict, name: str, address: str | None) -> tuple[str, str, dict] | None:
    """Picks the keyboard out of what BlueZ's object manager knows of.

    `objects` is path to interface to properties, as GetManagedObjects gives
    it. Returns what bleak's BLEDevice is made of on Linux: the address, the
    name, and the details its client reads the D-Bus path and the device's
    properties from. A device that is connected is preferred, then one that
    is paired, in case the name has been used more than once.
    """
    found = []
    for path, interfaces in objects.items():
        props = interfaces.get(DEVICE_INTERFACE)
        if not props or not props.get("Address"):
            continue
        if address:
            if props["Address"].upper() != address.upper():
                continue
        elif name not in (props.get("Alias"), props.get("Name")):
            continue
        rank = (bool(props.get("Connected")), bool(props.get("Paired")))
        found.append((rank, path, props))
    if not found:
        return None
    _rank, path, props = max(found, key=lambda entry: entry[0])
    return props["Address"], props.get("Alias") or name, {"path": path, "props": props}


def ble_device(address: str, name: str, details):
    """A BLEDevice for a keyboard that was not scanned for.

    Given an address, bleak scans for the device before connecting, and a
    keyboard that is connected to its computer does not advertise: it is never
    found. Given a BLEDevice it connects without looking. Its WinRT client
    reads only the address from one; its BlueZ client reads `details["path"]`
    and `details["props"]`.
    """
    from bleak.backends.device import BLEDevice

    try:
        return BLEDevice(address, name, details)
    except TypeError:  # before bleak 1.0 a signal strength was wanted too
        return BLEDevice(address, name, details, 0)


async def find_device(name: str, address: str | None):
    """The keyboard as a BLEDevice, or None if this computer does not have it connected."""
    if sys.platform == "win32":
        address = address or await asyncio.to_thread(find_address, name)
        if not address:
            log_once(f"no paired keyboard named {name!r}; pair it first, or pass --address")
            return None
        return ble_device(address, name, None)

    from bleak.backends.bluezdbus.manager import get_global_bluez_manager

    # Its picture of BlueZ comes from the object manager and from the signals
    # that follow. No discovery is started to get it.
    manager = await get_global_bluez_manager()
    objects = getattr(manager, "_properties", None)
    found = bluez_device(objects, name, address) if isinstance(objects, dict) else None
    if found is None and not isinstance(objects, dict):
        # A bleak that keeps it somewhere else. The path can be worked out,
        # given the address.
        address = address or await asyncio.to_thread(find_address, name)
        if address:
            adapter = manager.get_default_adapter()
            path = f"{adapter}/dev_{address.upper().replace(':', '_')}"
            props = {"Address": address, "Alias": name, "Adapter": adapter, "Connected": manager.is_connected(path)}
            found = (address, name, {"path": path, "props": props})

    if found is None:
        log_once(f"no paired keyboard named {name!r}; pair it first, or pass --address")
        return None
    if not found[2]["props"].get("Connected"):
        # Connecting is the system's business, as it is for typing. This
        # only joins a link that is already there.
        log_once("the keyboard is not connected to this computer just now")
        return None
    return ble_device(*found)


async def release(client) -> bool:
    """Lets go of the keyboard without disconnecting it.

    On Windows bleak's disconnect closes its own session with the device and
    the objects it holds, and the system's link to the keyboard stays. On
    Linux it calls Device1.Disconnect, which drops the whole link, typing
    included. So there this does what that disconnect does apart from that
    one call: it stops the notifications, ends the task that would send the
    Disconnect if it were ever cancelled, lets go of the watcher, and closes
    the D-Bus connection, at which BlueZ forgets this client.

    Returns False if bleak has changed underneath and it could not be done,
    in which case the client is simply dropped.
    """
    if sys.platform == "win32":
        try:
            await client.disconnect()
        except Exception as error:  # the link may already be gone
            log(f"could not close the session cleanly ({describe(error)})")
        return True

    backend = getattr(client, "_backend", None)
    try:
        if client.is_connected:
            try:
                await client.stop_notify(TX_UUID)
            except Exception:  # never started, or the link went first
                pass
        monitor = backend._disconnect_monitor_event
        if monitor is not None:
            monitor.set()
            backend._disconnect_monitor_event = None
        backend._cleanup_all()
        bus = backend._bus
        if bus is not None:
            bus.disconnect()
            try:
                await asyncio.wait_for(bus.wait_for_disconnect(), 2)
            except asyncio.TimeoutError:
                pass
            backend._bus = None
        backend._is_connected = False
        return True
    except Exception as error:  # private parts of bleak, which may move
        log(f"could not let go of the keyboard cleanly ({describe(error)})")
        return False


# ---- The link ----


def beside(work) -> asyncio.Task:
    """Runs `work` as a task whose failure is logged rather than left lying."""

    def finished(task: asyncio.Task) -> None:
        if not task.cancelled() and task.exception() is not None:
            log(f"gave up on a transfer ({describe(task.exception())})")

    task = asyncio.ensure_future(work)
    task.add_done_callback(finished)
    return task


async def gone(task: asyncio.Task | None) -> None:
    """Cancels a task and waits until it has stopped."""
    if task is None:
        return
    task.cancel()
    await asyncio.wait([task])
    if not task.cancelled():
        task.exception()


class Fetch:
    """A copy made on another computer that is being fetched."""

    def __init__(self, offer: Offer, crc: int, started: float) -> None:
        self.offer = offer
        # Checksum of the OFFER, which is what the keyboard is told has been
        # dealt with.
        self.crc = crc
        self.started = started
        self.wants = 0
        self.events: asyncio.Queue[tuple] = asyncio.Queue()
        self.task: asyncio.Task | None = None
        # The HOLD repeats. They outlast the task when the content arrives
        # through the keyboard, and stop only as the ACK goes out.
        self.holding: asyncio.Task | None = None


# What became of content that was to be put on the clipboard.
PLACED, FAILED, STALE = "placed", "failed", "stale"


class Bridge:
    """One connection to the keyboard, and everything that passes over it.

    Two loops run side by side. `listen` takes the keyboard's frames in the
    order they come. `watch` looks at the clipboard and sends what is copied
    here. Neither waits on the other, so a slow clipboard does not hold up an
    acknowledgement the keyboard is waiting for. What has to wait on the
    network runs as tasks beside them: fetching a copy another computer has
    offered, and getting a copy made here to a helper that could not fetch it.
    """

    def __init__(self, client, clipboard, name: str, endpoint: Endpoint) -> None:
        self.client = client
        self.clipboard = clipboard
        self.name = name
        self.endpoint = endpoint
        self.assembler = Assembler()
        # When the last frame of a delivery arrived, and whether one that
        # has arrived whole is still being put on the clipboard.
        self.delivery_heard = 0.0
        self.accepting = False

        # From the keyboard's STATUS frame.
        self.version = 1
        self.max_length = 4096
        self.max_opaque = 0

        self.incoming: asyncio.Queue[bytes] = asyncio.Queue()
        self.quick_looks = 0
        self.poked = asyncio.Event()

        # What the clipboard looked like when it was last dealt with.
        self.seen: object = None
        # What was last sent from here, and whose it was, so that the same
        # thing is not sent again because its marker moved; and what this
        # helper last put on the clipboard itself, so that is not sent back.
        self.sent: tuple[bytes, object] | None = None
        self.placed: bytes | None = None
        # Held across a write to the clipboard and the reading of its marker
        # afterwards, so the poll never sees the one without the other.
        self.board = asyncio.Lock()
        # Clipboard calls run on other threads, so that a slow one does not
        # hold up the link, and one whose caller was cancelled runs to its
        # end there regardless. This keeps the next from starting before it.
        self.board_thread = threading.Lock()

        # Counts the clips sent, so one overtaken by a newer copy stops.
        self.serial = 0
        self.sending = asyncio.Lock()
        self.pushing: asyncio.Task | None = None

        self.fetch: Fetch | None = None
        # The copy whose fetch was abandoned because something was copied
        # here instead. If its content turns up anyway, it is not wanted.
        self.abandoned: bytes | None = None
        self.answering: asyncio.Task | None = None

    def frame_cap(self) -> int:
        try:
            rx = self.client.services.get_characteristic(RX_UUID)
            cap = getattr(rx, "max_write_without_response_size", 20) or 20
        except Exception:  # bleak asserts on a session that has just gone
            cap = 20
        return max(20, min(cap, 244))

    async def send(self, frame: bytes) -> None:
        await self.client.write_gatt_char(RX_UUID, frame, response=False)

    def on_notify(self, _sender, data: bytearray) -> None:
        if data:
            self.incoming.put_nowait(bytes(data))

    async def send_clip(self, payload: bytes, flags: int) -> bool:
        """Sends one clip, unless a newer copy overtakes it on the way."""
        self.serial += 1
        serial = self.serial
        async with self.sending:
            for frame in transfer(payload, flags, self.frame_cap()):
                if serial != self.serial:
                    return False
                await self.send(frame)
        return True

    async def clear(self) -> None:
        # Told to drop what it has, the keyboard can never go on to deliver
        # something older than the most recent copy.
        self.serial += 1
        await self.send(bytes([CLEAR]))

    async def relay(self, datagram: bytes) -> None:
        await self.send(bytes([RELAY]) + datagram)

    async def on_board(self, call, *arguments):
        """Makes one call on the clipboard, off the event loop."""

        def alone():
            with self.board_thread:
                return call(*arguments)

        return await asyncio.to_thread(alone)

    async def own_addresses(self) -> list[str]:
        """This computer's addresses, without letting a slow name lookup hold a copy up."""
        try:
            return await asyncio.wait_for(asyncio.to_thread(self.endpoint.addresses), 0.5)
        except asyncio.TimeoutError:
            return usable(routed_addresses())

    def can_offer(self) -> bool:
        """Whether the keyboard passes an OFFER on."""
        return self.version >= 2 and self.max_opaque >= MIN_OPAQUE

    def busy(self) -> bool:
        """A delivery is arriving or being dealt with, or a fetch is running.

        The periodic HELLO is held off meanwhile: the keyboard takes one to
        mean a helper that has only just started, and would begin the delivery
        again. A delivery only counts as arriving while frames keep coming.
        The keyboard can abandon one without a word, and a helper that then
        never said HELLO again would never be delivered to again.
        """
        arriving = (
            self.assembler.active
            and asyncio.get_running_loop().time() - self.delivery_heard < DELIVERY_IDLE_SECONDS
        )
        return self.fetch is not None or arriving or self.accepting

    # -- This computer's clipboard, outbound --

    def same_as_before(self, clip: Clip) -> bool:
        """Whether `clip` is only what was already sent from here or put here.

        Windows moves its clipboard number on when a format is rendered that
        had only been promised, and this helper's own reading can be what has
        it rendered. A move with the same owner and the same content is that,
        not a copy.
        """
        mark = clip.fingerprint()
        return mark == self.placed or (clip.owner is not None and (mark, clip.owner) == self.sent)

    async def check_clipboard(self, poked: bool) -> None:
        """Looks for a new copy on this computer, and sends it if there is one."""
        async with self.board:
            marker = await self.on_board(self.clipboard.marker, poked)
            if marker == self.seen:
                return
            clip = await self.on_board(self.clipboard.read)
            if clip is None:
                # Could not look: another program has the clipboard open. It
                # is not marked as seen, and so is looked at again next time.
                return
            self.seen = marker if clip.after is None else clip.after

        # A copy shortcut the keyboard saw is a copy, whatever it copied.
        if not poked and self.same_as_before(clip):
            return
        self.quick_looks = 0
        self.sent = (clip.fingerprint(), clip.owner)
        self.placed = None
        await self.local_copy(clip)

    async def local_copy(self, clip: Clip) -> None:
        """Something was copied here: it is the latest copy now, in place of anything in hand."""
        fetch = self.fetch
        if fetch:
            await self.end_fetch()
            self.abandoned = fetch.offer.ticket
            if fetch.wants:
                # The computer it was copied on may be about to send it
                # through the keyboard, which would replace this copy there.
                # Said before the copy itself goes, while the keyboard still
                # knows where to pass it.
                await self.relay(bytes([CANCEL]) + fetch.offer.ticket)
            await self.send(bytes([HOLD, HOLD_OFF]))
            log("stopped fetching: something was copied here")

        # Only the latest copy is on offer, whatever kind it turns out to be.
        self.endpoint.offering = None
        await gone(self.answering)
        await gone(self.pushing)
        self.pushing = beside(self.push(clip))

    async def push(self, clip: Clip) -> None:
        """Hands the keyboard what was just copied here."""
        payload = text_bytes(clip.text) if clip.text else b""

        if clip.private:
            log("skipped a concealed item")
        elif payload and len(payload) <= self.max_length:
            log(f"sending {len(payload)} bytes")
            await self.send_clip(payload, keyboard_on_usb(self.name))
            return
        elif payload and self.can_offer():
            await self.offer(KIND_TEXT, lambda: payload, f"{len(payload)} bytes of text")
            return
        elif payload:
            log(f"skipped {len(payload)} bytes, over the keyboard's {self.max_length}")
        elif clip.image and self.can_offer():
            await self.offer(clip.kind(), clip.content, "an image")
            return
        elif clip.image:
            log("skipped an image; this keyboard's firmware carries text only")

        await self.clear()

    async def offer(self, kind: int, produce, what: str) -> None:
        """Puts a copy on offer and sends the keyboard the message that says where."""
        offering = Offering(kind, produce)
        # With no port to be reached at, the other helper still gets to hear
        # of the copy, and asks for it another way.
        port = self.endpoint.port
        addresses = await self.own_addresses() if port else []
        message = Offer(kind, offering.ticket, offering.key, port, addresses).encode(self.max_opaque)
        self.endpoint.offering = offering
        log(f"offering {what} to the next computer")
        await self.send_clip(message, keyboard_on_usb(self.name) | OPAQUE)

    async def answer(self, offering: Offering, port: int, addresses: list[str]) -> None:
        """Gets the copy on offer to a helper that could not come for it.

        Over the network if this side can connect where the other could not,
        and otherwise through the keyboard, cut down to fit.
        """
        try:
            content = await offering.content()
        except Exception as error:  # Pillow raises a variety of things on a bad image
            log(f"could not read the copy on offer ({describe(error)})")
            await self.relay(bytes([GONE]) + offering.ticket)
            return

        if addresses and await self.endpoint.put(addresses, port, offering):
            log(f"handed over {len(content)} bytes over the network")
            return

        room = min(self.max_opaque, INLINE_BUDGET)
        message = await asyncio.to_thread(encode_inline, offering.kind, offering.ticket, content, room)
        if self.endpoint.offering is not offering:
            return
        if message is None:
            log("too much to send through the keyboard, and the other computer cannot be reached over the network")
            await self.relay(bytes([GONE]) + offering.ticket)
            return

        log(f"sending {len(message)} bytes through the keyboard")
        await self.send_clip(message, keyboard_on_usb(self.name) | OPAQUE)

    async def on_relay(self, datagram: bytes) -> None:
        """A datagram from the helper at the other end of the clip."""
        if not datagram:
            return
        ticket = datagram[1:9]
        offering = self.endpoint.offering

        if datagram[0] == GONE and len(datagram) >= 9:
            if self.fetch and ticket == self.fetch.offer.ticket:
                self.fetch.events.put_nowait(("gone",))
            return

        if datagram[0] == CANCEL and len(datagram) >= 9:
            # Something newer was copied on the computer that asked. An
            # INLINE now would replace that in the keyboard.
            if offering and offering.ticket == ticket:
                self.endpoint.offering = None
                await gone(self.answering)
                log("the other computer no longer wants what was copied here")
            return

        want = parse_want(datagram) if datagram[0] == WANT else None
        if want is None:
            return
        ticket, port, addresses = want
        if offering is None or offering.ticket != ticket:
            # Something has been copied here since. Saying so spares the
            # other helper a long wait for content that is not coming.
            await self.relay(bytes([GONE]) + ticket)
            return
        if self.answering and not self.answering.done():
            return
        self.answering = beside(self.answer(offering, port, addresses))

    # -- Another computer's clip, inbound --

    async def place(
        self, kind: int, content: bytes, crc: int, how: str, holding: asyncio.Task | None = None
    ) -> str:
        """Puts delivered content on the clipboard and acknowledges it.

        `how` is the log line, with `{}` where the size goes. `holding` is
        the task repeating HOLD, if one is: it runs on through the making of
        the image and the writing of it, which can take a while, and is
        stopped only as the acknowledgement goes out. A HOLD after the
        acknowledgement would have the keyboard keeping pastes back again.
        """
        try:
            async with self.board:
                # Something copied here since the last look is newer than
                # what has just arrived, and must not be written over. Before
                # the first look there is nothing to compare with: whatever
                # is there was copied before this helper was listening.
                marker = await self.on_board(self.clipboard.marker, False)
                if self.seen is not None and marker != self.seen:
                    current = await self.on_board(self.clipboard.read)
                    if current is not None and not self.same_as_before(current):
                        return STALE

                try:
                    if kind == KIND_TEXT:
                        text = content.decode("utf-8", errors="replace")
                        mark = fingerprint(KIND_TEXT, text_bytes(text))
                        written = await self.on_board(self.clipboard.write, text)
                    else:
                        png = await asyncio.to_thread(to_png, kind, content)
                        mark = fingerprint(KIND_PNG, png)
                        written = await self.on_board(self.clipboard.write_image, png)
                except Exception as error:  # Pillow raises a variety of things on a bad image
                    log(f"could not make sense of what arrived ({describe(error)})")
                    written = False
                if not written:
                    log("could not set the clipboard")
                    return FAILED

                await gone(holding)
                holding = None
                # The acknowledgement is what tells the keyboard to let the
                # paste through instead of typing the clip.
                await self.send(bytes([ACK]) + crc.to_bytes(4, "little"))
                self.placed = mark
                log(how.format(len(content)))
                await asyncio.sleep(0.1)  # let the clipboard settle before reading its marker
                # Not a fresh look: where looking is costly it is not worth
                # one, and if the marker moves late, what is then read is
                # recognised as this.
                self.seen = await self.on_board(self.clipboard.marker, False)
                return PLACED
        finally:
            if holding is not None:
                holding.cancel()

    async def accept(self, payload: bytes, crc: int, flags: int) -> None:
        """A whole clip has arrived from the keyboard."""
        if not flags & OPAQUE:
            # A different clip from the one being fetched, if one was.
            await self.end_fetch()
            await self.place(KIND_TEXT, payload, crc, "took delivery of {} bytes")
            return

        offer = Offer.parse(payload)
        inline = parse_inline(payload)
        if offer:
            await self.end_fetch()
            self.start_fetch(offer, crc)
        elif inline:
            kind, ticket, content = inline
            # Whether or not a fetch here was waiting for exactly this, it
            # has arrived whole and there is nothing left to fetch. If one
            # was, its HOLD repeats run on until this is on the clipboard.
            holding = await self.end_fetch(keep_holding=True)
            if ticket == self.abandoned:
                # Asked for before something was copied here instead. The
                # acknowledgement still goes, so a paste is not held for it.
                await gone(holding)
                await self.send(bytes([ACK]) + crc.to_bytes(4, "little"))
                return
            await self.place(kind, content, crc, "took delivery of {} bytes through the keyboard", holding)
        else:
            # From a newer helper than this one. Acknowledged all the same,
            # so that a paste here is not kept waiting on it.
            await self.end_fetch()
            await self.send(bytes([ACK]) + crc.to_bytes(4, "little"))
            log("the other computer sent something this version cannot read")

    def start_fetch(self, offer: Offer, crc: int) -> None:
        fetch = Fetch(offer, crc, asyncio.get_running_loop().time())
        self.fetch = fetch
        fetch.holding = beside(self.keep_holding(fetch))
        fetch.task = beside(self.run_fetch(fetch))

    async def keep_holding(self, fetch: Fetch) -> None:
        """Asks the keyboard, over and over, to keep pastes back while the fetch runs.

        Said at once and then repeated, so that a paste pressed meanwhile
        waits instead of putting down whatever the clipboard held before. If
        the copy has not come by the time both ways over the network have had
        their chance, it is coming the slow way or as a long download, and a
        paste is not worth holding for either: from then on the keyboard is
        told to drop pastes instead.
        """
        loop = asyncio.get_running_loop()
        slow_from = fetch.started + CONNECT_SECONDS + PUT_WAIT_SECONDS
        await self.send(bytes([HOLD, HOLD_SOON]))
        while True:
            left = slow_from - loop.time()
            await asyncio.sleep(min(HOLD_SECONDS, left) if left > 0 else HOLD_SECONDS)
            soon = loop.time() + 0.001 < slow_from
            await self.send(bytes([HOLD, HOLD_SOON if soon else 0]))

    async def run_fetch(self, fetch: Fetch) -> None:
        """Fetches the copy an OFFER names, by whichever way works; see PROTOCOL.md."""
        try:
            found = await self.find(fetch)

            outcome = FAILED
            if isinstance(found, tuple):
                outcome = await self.place(*found, fetch.holding)
            else:
                log(f"could not fetch what was copied on the other computer: {found}")
            await gone(fetch.holding)

            if outcome == STALE:
                # Something was copied here while it was on its way. The
                # watch loop sends that; all there is to say here is that
                # nothing is being fetched any more.
                await self.send(bytes([HOLD, HOLD_OFF]))
            elif outcome == FAILED:
                await self.send(bytes([HOLD, HOLD_OFF]))
                await self.send(bytes([ACK]) + fetch.crc.to_bytes(4, "little"))
        except asyncio.CancelledError:
            # Ended from outside, which also decides what becomes of the
            # HOLD repeats.
            raise
        except Exception:
            if fetch.holding:
                fetch.holding.cancel()
            raise
        finally:
            if self.endpoint.awaiting and self.endpoint.awaiting[0] == fetch.offer.ticket:
                self.endpoint.awaiting = None
            if self.fetch is fetch:
                self.fetch = None

    async def find(self, fetch: Fetch):
        """Goes through the ways a copy can come until one of them works.

        Returns what `place` takes: the kind, the content, the checksum to
        acknowledge and the wording for the log. Or, if none worked, the
        reason as a string. Content that comes through the keyboard arrives
        as a clip like any other, and `accept` ends the fetch when it does.
        """
        offer = fetch.offer

        content = await self.endpoint.get(offer)
        if content is not None:
            return offer.kind, content, fetch.crc, "fetched {} bytes over the network"

        # Nothing answered where the copy was offered, or the stream failed.
        # The computer it was made on may still be able to connect here, and
        # if not, it can send the content through the keyboard.
        def brought(content: bytes) -> None:
            fetch.events.put_nowait(("put", content))

        self.endpoint.awaiting = (offer.ticket, offer.key, brought)
        room = min(RELAY_MAX, self.frame_cap()) - 1
        port = self.endpoint.port
        fetch.wants += 1
        await self.relay(encode_want(offer.ticket, port, await self.own_addresses() if port else [], room))

        loop = asyncio.get_running_loop()
        until = loop.time() + PUT_WAIT_SECONDS + INLINE_WAIT_SECONDS
        while True:
            try:
                event = await asyncio.wait_for(fetch.events.get(), max(0, until - loop.time()))
            except asyncio.TimeoutError:
                return "nothing came of asking for it"

            if event[0] == "put":
                return offer.kind, event[1], fetch.crc, "was handed {} bytes over the network"
            if event[0] == "gone":
                return "it is no longer there to be fetched"
            if event[0] == "unreachable":
                if fetch.wants > 1:
                    return "the computer it was copied on is out of reach"
                # It may only have been too long for the link at the other
                # end. With no addresses in it, it is as short as it gets.
                fetch.wants += 1
                await self.relay(encode_want(offer.ticket, port, [], room))

    async def end_fetch(self, keep_holding: bool = False) -> asyncio.Task | None:
        """Stops fetching, without a word to the keyboard.

        With `keep_holding` the HOLD repeats are left running and handed
        back, for the caller to stop when it has an acknowledgement to send.
        """
        fetch, self.fetch = self.fetch, None
        if fetch is None:
            return None
        await gone(fetch.task)
        if self.endpoint.awaiting and self.endpoint.awaiting[0] == fetch.offer.ticket:
            self.endpoint.awaiting = None
        if keep_holding and fetch.holding and not fetch.holding.done():
            return fetch.holding
        await gone(fetch.holding)
        return None

    # -- The two loops --

    async def handle(self, frame: bytes) -> None:
        """Processes one frame from the keyboard."""
        kind = frame[0]
        if kind == STATUS and len(frame) >= 4:
            self.version = frame[1]
            self.max_length = int.from_bytes(frame[2:4], "little")
            self.max_opaque = int.from_bytes(frame[4:6], "little") if len(frame) >= 6 else 0
            ability = ", and passes on images" if self.can_offer() else "; its firmware carries text only"
            log(f"keyboard holds up to {self.max_length} bytes of text{ability}")
        elif kind == RESULT and len(frame) >= 2 and frame[1] == UNREACHABLE:
            # The keyboard had no helper to pass the last RELAY to.
            if self.fetch and self.fetch.wants:
                self.fetch.events.put_nowait(("unreachable",))
        elif kind == RESULT and len(frame) >= 2 and frame[1] != 0:
            log(f"keyboard refused the clip (code {frame[1]})")
        elif kind == POKE:
            # The keyboard saw a copy shortcut go by. Looking now, rather than
            # on the next poll, is what lets a quick switch-and-paste carry
            # the new clip instead of the one before it.
            self.quick_looks = POKE_LOOKS
            self.poked.set()
        elif kind == BEGIN:
            self.assembler.begin(frame)
            self.delivery_heard = asyncio.get_running_loop().time()
        elif kind == DATA:
            self.assembler.feed(frame)
            self.delivery_heard = asyncio.get_running_loop().time()
        elif kind == END:
            clip = self.assembler.end()
            if clip is None:
                log("a delivered clip arrived damaged")
                return
            # Until it is acknowledged the keyboard still counts it as
            # being delivered.
            self.accepting = True
            try:
                await self.accept(*clip)
            finally:
                self.accepting = False
        elif kind == RELAY:
            await self.on_relay(frame[1:])

    async def listen(self) -> None:
        """Takes the keyboard's frames, in the order they come."""
        while True:
            await self.handle(await self.incoming.get())

    async def watch(self) -> None:
        """Looks at the clipboard, sends what is copied here, and keeps the keyboard's trust."""
        loop = asyncio.get_running_loop()
        # Only copies made from here on are carried.
        async with self.board:
            self.seen = await self.on_board(self.clipboard.marker, True)
        said_hello = loop.time()

        while self.client.is_connected:
            try:
                await asyncio.wait_for(self.poked.wait(), POKE_SECONDS if self.quick_looks else POLL_SECONDS)
            except asyncio.TimeoutError:
                pass
            self.poked.clear()

            poked = self.quick_looks > 0
            self.quick_looks = max(0, self.quick_looks - 1)
            await self.check_clipboard(poked)

            # The firmware stops waiting on a helper that misses an
            # acknowledgement; this is what gets it trusted again.
            if loop.time() - said_hello >= HELLO_SECONDS and not self.busy():
                said_hello = loop.time()
                await self.send(bytes([HELLO, VERSION, 0]))

    async def run(self) -> None:
        """Runs until the link drops."""
        await self.client.start_notify(TX_UUID, self.on_notify)
        await self.send(bytes([HELLO, VERSION, 0]))
        log("ready")

        loops = [asyncio.ensure_future(self.listen()), asyncio.ensure_future(self.watch())]
        try:
            done, _running = await asyncio.wait(loops, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in loops:
                if not task.done():
                    await gone(task)
        for task in done:
            if not task.cancelled() and task.exception() is not None:
                raise task.exception()

    async def close(self) -> None:
        """Stops what was running beside the loops. The link is gone or going."""
        await self.end_fetch()
        await gone(self.answering)
        await gone(self.pushing)


async def session(client, clipboard, name: str, endpoint: Endpoint) -> None:
    """One connection's worth of carrying, from HELLO until the link goes.

    Whatever goes wrong in it is logged, not raised. Nothing the keyboard,
    the clipboard or bleak does is a reason for the helper to stop.
    """
    bridge = Bridge(client, clipboard, name, endpoint)
    try:
        await bridge.run()
    except Exception as error:
        log(f"link lost ({describe(error)})")
    finally:
        try:
            await bridge.close()
            if client.is_connected:
                # So the next paste here does not wait on an acknowledgement
                # that will never come.
                await bridge.send(bytes([BYE]))
        except Exception:
            pass


async def attempt(
    args: argparse.Namespace, clipboard, endpoint: Endpoint, state: dict, find=None, make_client=None
) -> None:
    """Finds the keyboard, joins its link, and carries until that link goes."""
    if make_client is None:
        from bleak import BleakClient as make_client

    device = await (find or find_device)(args.name, args.address)
    if device is None:
        return

    options = {}
    if sys.platform == "win32":
        # Windows caches a paired device's services, and a cache from before
        # the firmware gained the clipboard service would hide it. It also
        # sometimes wants to be told what kind of address it is being given;
        # each kind is tried in turn until one is found.
        kinds = (None, "random", "public")
        kind = kinds[state.get("address_kind", 0) % len(kinds)]
        options = {"winrt": {"use_cached_services": False, **({"address_type": kind} if kind else {})}}

    log_once(f"connecting to {device.address}")
    client = make_client(device, **options)
    unsupported = False
    try:
        joining = asyncio.ensure_future(client.connect())
        try:
            await asyncio.shield(joining)
        except asyncio.CancelledError:
            # Told to stop in the middle of joining. Cancelled there, bleak
            # disconnects the keyboard on its way out on Linux. Left to
            # finish, it does not, and the link can then be let go of.
            await asyncio.wait([joining], timeout=10)
            if joining.done() and not joining.cancelled():
                joining.exception()
            raise
        except Exception as error:
            if type(error).__name__ == "BleakDeviceNotFoundError":
                state["address_kind"] = state.get("address_kind", 0) + 1
            raise

        if client.services.get_service(SERVICE_UUID) is None:
            log_once("the keyboard's firmware has no clipboard service")
            unsupported = True
        else:
            await session(client, clipboard, args.name, endpoint)
    finally:
        if not await release(client):
            state["unreleased"] = True

    if unsupported:
        # Let go of first, and only then left alone for a while.
        await asyncio.sleep(UNSUPPORTED_SECONDS)


async def serve(args: argparse.Namespace, clipboard, endpoint: Endpoint, state: dict, once=attempt) -> None:
    """Carries for as long as the helper runs, through every loss of the link."""
    while True:
        try:
            await once(args, clipboard, endpoint, state)
        except Exception as error:  # nothing short of being told to stop ends the helper
            log_once(f"no link to the keyboard ({describe(error)})")
        await asyncio.sleep(RETRY_SECONDS)


async def main(args: argparse.Namespace) -> None:
    clipboard = await asyncio.to_thread(WindowsClipboard if sys.platform == "win32" else LinuxClipboard)

    endpoint = Endpoint()
    try:
        await endpoint.start()
    except OSError as error:
        log(f"cannot listen on the network ({error}); the other helper will have to be the one to connect")

    state: dict = {}
    serving = asyncio.ensure_future(serve(args, clipboard, endpoint, state))

    # Stopped by signal rather than by KeyboardInterrupt where that can be
    # had: what is in hand is then put down in order, and on Linux nothing is
    # cancelled that would take the keyboard's link down with it.
    stop = asyncio.Event()
    try:
        for number in (signal.SIGINT, signal.SIGTERM):
            asyncio.get_running_loop().add_signal_handler(number, stop.set)
    except (NotImplementedError, RuntimeError, ValueError):
        pass

    stopping = asyncio.ensure_future(stop.wait())
    try:
        await asyncio.wait([serving, stopping], return_when=asyncio.FIRST_COMPLETED)
    finally:
        await gone(stopping)
        await gone(serving)
        await endpoint.stop()
        if hasattr(clipboard, "close"):
            clipboard.close()

    if state.get("unreleased") and sys.platform != "win32":
        # bleak could not be made to let go of the keyboard. Winding the
        # event loop down the usual way would cancel the task of its that
        # disconnects the keyboard when cancelled, so the process ends here
        # instead, without that.
        sys.stdout.flush()
        os._exit(0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Clipboard helper for the M0110 converter.")
    parser.add_argument("--name", default="M0110", help="Bluetooth name of the keyboard")
    parser.add_argument("--address", help="Bluetooth address, if it cannot be found by name")
    parser.add_argument("-v", "--verbose", action="store_true", help="log what is happening")
    arguments = parser.parse_args()
    verbose = arguments.verbose

    if sys.platform == "darwin":
        sys.exit("On a Mac, M0110HUD carries the clipboard; this helper is for Windows and Linux.")

    try:
        asyncio.run(main(arguments))
    except KeyboardInterrupt:
        pass
