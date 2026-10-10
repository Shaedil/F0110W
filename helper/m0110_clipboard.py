#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["bleak>=1.0", "cryptography>=41", "pillow>=9.1"]
# ///
"""Clipboard helper for the M0110 converter, for Windows and Linux.

The keyboard cannot read a clipboard, so a helper sends each new copy to it and
places clips that arrive from other computers (M0110HUD does this on a Mac).
Images and long text go between helpers over the network, or through the
keyboard cut down to fit if the helpers cannot connect. Without a helper, the
keyboard types text out and images do not arrive.

    uv run m0110_clipboard.py            # or: pip install bleak cryptography pillow
    uv run m0110_clipboard.py --verbose

The keyboard must already be paired. Keyboard frames are in the firmware's
config/clipboard/clip_proto.h, and the helper-to-helper protocol is in PROTOCOL.md.
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
# Longest RELAY frame the keyboard passes on, including the type byte.
RELAY_MAX = 64

# Helper-to-helper messages, see PROTOCOL.md.
KIND_TEXT, KIND_PNG, KIND_JPEG = 1, 2, 3
KINDS = (KIND_TEXT, KIND_PNG, KIND_JPEG)
OFFER, INLINE = 0x01, 0x02
WANT, GONE, CANCEL = 0x01, 0x02, 0x03
GET, PUT = 1, 2
MAGIC = b"M0CB\x01"
# Sent back by the receiver once it has decrypted the final record.
TAKEN = b"\x01"
RECORD_MAX = 65536
TAG_LENGTH = 16
MAX_ADDRESSES = 6
# Smallest keyboard buffer that fits an OFFER with every address.
MIN_OPAQUE = 256
# Caps how much a bad peer can make this script buffer.
MAX_CONTENT = 256 * 1024 * 1024
# Largest INLINE to send. Anything bigger takes too long to get through the keyboard.
INLINE_BUDGET = 40000

# ZMK's default USB IDs, which this firmware keeps.
USB_VENDOR, USB_PRODUCT = "1d50", "615e"

POLL_SECONDS = 0.4
# After a copy shortcut, poll this fast for POKE_LOOKS rounds.
POKE_SECONDS = 0.05
POKE_LOOKS = 6
HELLO_SECONDS = 30
RETRY_SECONDS = 5
UNSUPPORTED_SECONDS = 60
CONNECT_SECONDS = 1.0
PUT_WAIT_SECONDS = 1.5
INLINE_WAIT_SECONDS = 90
HOLD_SECONDS = 0.4
# How long a connecting helper gets to send its opening bytes.
HELLO_WAIT_SECONDS = 5
# A stream that makes no progress for this long is given up.
IDLE_SECONDS = 10
# A delivery with no new frame for this long is treated as abandoned.
DELIVERY_IDLE_SECONDS = 3
# How often to re-read an image on a clipboard that has no change counter.
IMAGE_POLL_SECONDS = 2.0
# Caps how much a bad peripheral can make this script buffer.
MAX_INCOMING = 65535

verbose = False


def log(message: str) -> None:
    if verbose:
        print(f"clipboard: {message}", flush=True)


last_said = ""


def log_once(message: str) -> None:
    global last_said
    if message != last_said:
        last_said = message
        log(message)


def describe(error: BaseException) -> str:
    return f"{type(error).__name__}: {error}" if str(error) else type(error).__name__


def text_bytes(text: str) -> bytes:
    """UTF-8 with LF endings. A lone surrogate from a Windows clipboard becomes a question mark."""
    return text.replace("\r\n", "\n").encode("utf-8", errors="replace")


# ---- Wire format ----


def transfer(payload: bytes, flags: int, frame_cap: int) -> list[bytes]:
    crc = zlib.crc32(payload)
    frames = [bytes([BEGIN, flags]) + len(payload).to_bytes(2, "little") + crc.to_bytes(4, "little")]
    room = max(1, frame_cap - 3)
    for offset in range(0, len(payload), room):
        frames.append(bytes([DATA]) + offset.to_bytes(2, "little") + payload[offset : offset + room])
    frames.append(bytes([END]))
    return frames


class Assembler:
    """Rebuilds a delivered clip. DATA must arrive in order, and any error drops the whole clip."""

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


# ---- Helper-to-helper messages ----


def pack_addresses(addresses: list[str], room: int) -> bytes:
    """Packs as many addresses as fit in `room` bytes as `count { family addr }*`."""
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
    def __init__(self, kind: int, ticket: bytes, key: bytes, port: int, addresses: list[str]) -> None:
        self.kind = kind
        self.ticket = ticket
        self.key = key
        self.port = port
        self.addresses = addresses

    def encode(self, room: int = MAX_INCOMING) -> bytes | None:
        head = bytes([OFFER, self.kind]) + self.ticket + self.key + self.port.to_bytes(2, "little")
        if len(head) + 1 > room:
            return None
        return head + pack_addresses(self.addresses, room - len(head))

    @classmethod
    def parse(cls, payload: bytes) -> Offer | None:
        if len(payload) < 45 or payload[0] != OFFER or payload[1] not in KINDS:
            return None
        addresses = unpack_addresses(payload[44:])
        if addresses is None:
            return None
        port = int.from_bytes(payload[42:44], "little")
        return cls(payload[1], payload[2:10], payload[10:42], port, addresses)


def encode_want(ticket: bytes, port: int, addresses: list[str], room: int) -> bytes:
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
    """Builds an INLINE of at most `room` bytes. Text must fit as is, and an image is scaled down to fit."""
    room -= 10
    if len(content) > room:
        if kind == KIND_TEXT:
            return None
        try:
            content = shrink(content, room)
        except Exception:  # Pillow can raise many error types on a bad image
            content = None
        if content is None:
            return None
        kind = KIND_JPEG
    return bytes([INLINE, kind]) + ticket + content


def parse_inline(payload: bytes) -> tuple[int, bytes, bytes] | None:
    if len(payload) < 10 or payload[0] != INLINE or payload[1] not in KINDS:
        return None
    return payload[1], payload[2:10], payload[10:]


# ---- Images ----


def opened(image: bytes):
    """Decodes an image upright, in a mode PNG can save.

    Cameras store rotation in an EXIF tag that re-encoding drops, so it is applied
    here. 16-bit grey is scaled to 8 bits, because a plain convert clips it to white.
    """
    from PIL import Image, ImageOps

    # Only what the protocol carries. Pillow would hand an EPS file to Ghostscript.
    picture = Image.open(io.BytesIO(image), formats=["PNG", "JPEG"])
    picture = ImageOps.exif_transpose(picture) or picture
    if picture.mode == "I" or picture.mode.startswith("I;16"):
        picture = picture.convert("I").point(lambda value: value * (1 / 256)).convert("L")
    elif picture.mode not in ("1", "L", "LA", "P", "RGB", "RGBA"):
        picture = picture.convert("RGB")
    return picture


def flatten(picture):
    from PIL import Image

    if picture.mode in ("RGBA", "LA") or "transparency" in picture.info:
        layer = picture.convert("RGBA")
        picture = Image.new("RGB", layer.size, (255, 255, 255))
        picture.paste(layer, mask=layer.split()[3])
    return picture.convert("RGB")


def to_png(kind: int, image: bytes) -> bytes:
    if kind == KIND_PNG:
        if not image.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("not a PNG")
        return image

    out = io.BytesIO()
    opened(image).save(out, "PNG")
    return out.getvalue()


def dib_to_png(dib: bytes) -> bytes:
    from PIL import BmpImagePlugin

    out = io.BytesIO()
    BmpImagePlugin.DibImageFile(io.BytesIO(dib)).save(out, "PNG")
    return out.getvalue()


def png_to_dib(png: bytes) -> bytes:
    """A DIB is a BMP file without its 14-byte file header."""
    out = io.BytesIO()
    flatten(opened(png)).save(out, "BMP")
    return out.getvalue()[14:]


def trim_png(data: bytes) -> bytes:
    """Drops bytes after IEND. Clipboard memory is rounded up in size, so there can be padding."""
    end = data.rfind(b"IEND")
    return data[: end + 8] if end >= 0 else data


# ---- Helper-to-helper stream ----


class TransferError(Exception):
    """A stream ended early, stalled, failed to decrypt or got too big."""


def hello(role: int, ticket: bytes) -> bytes:
    return MAGIC + bytes([role]) + ticket


def seal(key: bytes, ticket: bytes, content: bytes):
    cipher = ChaCha20Poly1305(key)
    count = max(1, -(-len(content) // RECORD_MAX))
    for number in range(count):
        last = 1 if number == count - 1 else 0
        nonce = bytes(4) + number.to_bytes(8, "little")
        chunk = content[number * RECORD_MAX : (number + 1) * RECORD_MAX]
        sealed = cipher.encrypt(nonce, chunk, ticket + bytes([last]))
        yield bytes([last]) + len(sealed).to_bytes(4, "little") + sealed


async def read_exactly(reader: asyncio.StreamReader, count: int) -> bytes:
    """Reads `count` bytes. The timeout is per read, so a large transfer that keeps moving has no time limit."""
    data = bytearray()
    while len(data) < count:
        piece = await asyncio.wait_for(reader.read(count - len(data)), IDLE_SECONDS)
        if not piece:
            raise asyncio.IncompleteReadError(bytes(data), count)
        data += piece
    return bytes(data)


async def read_content(reader: asyncio.StreamReader, writer, key: bytes, ticket: bytes) -> bytes:
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

    # The sender only counts the content as taken once it gets this byte.
    if writer is not None:
        try:
            writer.write(TAKEN)
            await asyncio.wait_for(writer.drain(), IDLE_SECONDS)
        except (asyncio.TimeoutError, OSError):
            pass
    return bytes(content)


async def write_content(reader, writer, key: bytes, ticket: bytes, content: bytes) -> bool:
    """Sends `content` as a stream. Returns True only if the receiver replies TAKEN."""
    try:
        # Progress is measured by drain() returning. With a large send buffer,
        # megabytes can still be unsent when it returns, so keep the buffer small.
        link = writer.get_extra_info("socket")
        if link is not None:
            link.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, RECORD_MAX)
        for record in seal(key, ticket, content):
            writer.write(record)
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
    """Connecting a UDP socket sends nothing. It only makes the system pick a source address."""
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
    if not shutil.which("ip"):
        return None
    try:
        done = subprocess.run(["ip", "-j", "addr"], capture_output=True, text=True, timeout=2)
        return parse_interfaces(done.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError, AttributeError, TypeError):
        return None


def local_addresses() -> list[str]:
    """Default route first. The host name is a last resort on Linux, where it is often only loopback."""
    found = routed_addresses()
    listed = interface_addresses()
    if listed is None:
        try:
            listed = [info[4][0] for info in socket.getaddrinfo(socket.gethostname(), None)]
        except OSError:
            listed = []
    return usable(found + listed)


def listening_socket() -> socket.socket:
    if socket.has_dualstack_ipv6():
        try:
            return socket.create_server(("", 0), family=socket.AF_INET6, dualstack_ipv6=True)
        except OSError:
            pass
    return socket.create_server(("", 0))


class Offering:
    """The latest copy made here. Content is made on first request, since converting a big bitmap to PNG is slow."""

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
    """One listener plus outgoing connections. Tests replace `dial` and `addresses`."""

    def __init__(self, dial=None, addresses=None) -> None:
        self.dial = dial or asyncio.open_connection
        self.addresses = addresses or local_addresses
        self.port = 0
        self.server = None
        self.offering: Offering | None = None
        # (ticket, key, callback) for a copy this helper asked to have PUT here.
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
                    # Only if this copy is still wanted and no other PUT delivered it first.
                    if self.awaiting is awaiting:
                        awaiting[2](content)
        except (TransferError, asyncio.IncompleteReadError, asyncio.TimeoutError, OSError):
            pass
        except Exception as error:  # producing the content can raise anything
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
            # In every case, including cancellation, stop the other attempts
            # and close any that already connected.
            for attempt in attempts:
                attempt.add_done_callback(discard)
                attempt.cancel()

    async def get(self, offer: Offer) -> bytes | None:
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


# ---- Clipboard ----


class Clip:
    """What is on the clipboard: text or an image, and whether it is private.

    `form` is "png", "jpeg", or "dib" (a Windows bitmap not yet converted to PNG).
    `owner` is who put it there, if the system says. `after` is the change marker
    taken after reading, for systems where reading can move it.
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
        """The image as it is sent. Slow for a large bitmap."""
        return dib_to_png(self.image) if self.form == "dib" else self.image

    def fingerprint(self) -> bytes:
        """A hash of the content, so the content itself is not kept."""
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
            # Handles are pointer-sized. Without these declarations ctypes
            # treats them as 32-bit ints and truncates them.
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

        # Password managers set these formats to keep secrets out of clipboard
        # history and cloud sync, and the keyboard should not carry them either.
        # Some set the first one. Others only set the other two, to zero.
        self.exclude_format = user32.RegisterClipboardFormatW("ExcludeClipboardContentFromMonitorProcessing")
        self.history_format = user32.RegisterClipboardFormatW("CanIncludeInClipboardHistory")
        self.cloud_format = user32.RegisterClipboardFormatW("CanUploadToCloudClipboard")
        # Browsers and image editors add PNG next to the bitmap. Only PNG keeps transparency.
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
            # The value is a DWORD, and zero means not allowed.
            if value is not None and not any(value[:4]):
                return True
        return False

    def read(self) -> Clip | None:
        """Returns None if another program has the clipboard open, which differs from an empty clipboard."""
        if not self._open(None, 10):
            return None
        try:
            owner = self.user32.GetClipboardOwner() or 0
            if self._private():
                clip = Clip(None, private=True)
            else:
                text = self._text()
                png = None if text else self._bytes(self.png_format)
                # Windows creates CF_DIB from any bitmap format, so this one covers them all.
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
        # Reading a format the owner only promised makes the owner render it,
        # which bumps the sequence number. Read the number again so this read
        # is not mistaken for a new copy.
        clip.after = self.user32.GetClipboardSequenceNumber()
        return clip

    def _put(self, kind: int, data: bytes) -> bool:
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
        """Replaces the clipboard contents, most descriptive format first.

        SetClipboardData fails after emptying a clipboard opened with no window,
        so a temporary window owns it. The window is destroyed before returning.
        """
        window = self.user32.CreateWindowExW(0, "STATIC", None, 0, 0, 0, 0, 0, None, None, None, None)
        if not window:
            return False
        try:
            # About one second, since a paste is waiting on this.
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
        except Exception:  # Pillow can raise many error types on a bad image
            return False
        # Most programs paste the bitmap. The PNG keeps transparency for those that read it.
        formats = [(self.png_format, png)] if self.png_format else []
        return self._write(formats + [(self.CF_DIB, dib)])


class LinuxClipboard:
    """wl-clipboard on Wayland, xclip or xsel on X11. None of them has a change counter.

    - Wayland with data-control: `wl-paste --watch` reports each change.
    - X11: checked every poll. An image is read once per copy, using the
      selection's TIMESTAMP, or re-read every so often if there is none.
    - Wayland without data-control (GNOME, for example): each wl-paste call takes
      focus for a moment, so xclip through XWayland is used if installed. If not,
      the clipboard is only checked after a copy shortcut.
    """

    # Set by KeePassXC and others on items that should not be recorded.
    PRIVATE_TYPE = "x-kde-passwordManagerHint"
    # In order of preference.
    TEXT_TYPES = ("text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT")
    IMAGE_TYPES = (("image/png", "png"), ("image/jpeg", "jpeg"))
    NOTHING = hashlib.sha256(b"").digest()

    def __init__(self, environ=None, which=shutil.which) -> None:
        environ = os.environ if environ is None else environ
        self.tool = ""
        # `wl-paste --watch` is running, and the number of changes it has reported.
        self.watching = False
        self.watcher = None
        self.changes = 0
        # No change events, and checking is too costly to do on every poll.
        self.poke_only = False
        self.last: object = (False, self.NOTHING)

        # Last image hash and read time, for owners that give no timestamp.
        self.image_seen: tuple[str, bytes] | None = None
        self.image_read = 0.0
        # Stop trusting an owner whose timestamp changes while its image stays the same.
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
        try:
            child = subprocess.Popen(
                ["wl-paste", "--watch", "echo"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            return False
        # Without the data-control protocol, wl-paste exits right away.
        try:
            child.wait(timeout=0.5)
            return False
        except subprocess.TimeoutExpired:
            pass
        self.watcher = child
        # Otherwise wl-paste keeps running after the helper exits.
        atexit.register(self.close)
        threading.Thread(target=self._count, args=(child,), daemon=True).start()
        return True

    def close(self) -> None:
        child, self.watcher = self.watcher, None
        if child is not None and child.poll() is None:
            child.terminate()

    def _count(self, child) -> None:
        for _line in child.stdout:
            self.changes += 1
        # wl-paste exited. Fall back to checking the clipboard on every poll.
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
            # With no -t, xclip offers text under all the usual text target names.
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
        command = self._types_command()
        listing = self._run(command) if command else None
        lines = listing.decode("utf-8", errors="replace").splitlines() if listing else []
        return [line.strip() for line in lines if line.strip()]

    def _text(self, offered: list[str]) -> bytes | None:
        """Asks only for a listed text type, since xclip answers any request with whatever it holds."""
        if self.tool == "xsel":
            return self._run(self._paste_command("")) or None
        if offered:
            wanted = next((name for name in self.TEXT_TYPES if name in offered), None)
        else:
            # The owner did not list its types. Try the usual name anyway.
            wanted = self.TEXT_TYPES[0] if self.tool == "wl" else "UTF8_STRING"
        return (self._run(self._paste_command(wanted)) or None) if wanted else None

    def _image(self, offered: list[str]) -> tuple[bytes, str] | None:
        if self.tool == "xsel":
            return None
        for mime, form in self.IMAGE_TYPES:
            if mime in offered:
                image = self._run(self._paste_command(mime), timeout=10)
                if image:
                    return image, form
        return None

    def _stamp(self, offered: list[str]) -> bytes | None:
        """The selection's TIMESTAMP. Only asked if listed, since xclip would reply with its content."""
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
            # Once can be the same image copied again. Repeated changes mean
            # the timestamp is useless.
            self.stamp_strikes += 1
            if self.stamp_strikes >= 3:
                self.stamps_trusted = False
                log("a program's clipboard timestamp changes by itself; images are read the slow way from now on")
        elif image[0] != self.read_image:
            self.stamp_strikes = 0
        self.read_stamp, self.read_image = stamp, image[0]
        return Clip(None, image=image[0], form=image[1])

    def marker(self, fresh: bool = False) -> object:
        """Stand-in for a change counter. `fresh` means a copy shortcut was just pressed."""
        if self.watching:
            return ("changes", self.changes)
        if self.poke_only and not fresh:
            return self.last
        self.last = self._look(fresh)
        return self.last

    def _look(self, fresh: bool) -> object:
        """A marker made from a hash of the content, so the clip itself is not kept in memory."""
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

        # Fetching an image makes its owner encode it again, so it is not done on every poll.
        stale = time.monotonic() - self.image_read >= IMAGE_POLL_SECONDS
        if fresh or stale or self.image_seen is None or self.image_seen[0] != listing:
            image = self._image(offered)
            self.image_seen = (listing, hashlib.sha256(image[0] if image else b"").digest())
            self.image_read = time.monotonic()
        return ("image", self.image_seen[1])

    def _hand_over(self, command: list[str], data: bytes) -> bool:
        # xclip and wl-copy keep running to serve the selection, so do not wait for them.
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
    """BEGIN flags saying whether the keyboard is also on this computer's USB.

    The firmware cannot tell this itself. If unknown, the keyboard leaves USB pastes alone.
    """
    if not sys.platform.startswith("linux"):
        return 0
    for device in glob.glob("/sys/bus/usb/devices/*"):
        try:
            with open(f"{device}/idVendor") as vendor, open(f"{device}/idProduct") as product:
                if vendor.read().strip() != USB_VENDOR or product.read().strip() != USB_PRODUCT:
                    continue
            # Every ZMK keyboard has these IDs, so check the product name too.
            with open(f"{device}/product") as label:
                if name.lower() in label.read().lower():
                    return USB_KNOWN | USB_LOCAL
        except OSError:
            continue
    return USB_KNOWN


# ---- Finding the keyboard ----


def find_address(name: str) -> str | None:
    """Looks up the keyboard in the OS paired-device list, since it does not advertise while connected."""
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
    """Picks the keyboard from GetManagedObjects as the (address, name, details) of a BLEDevice.

    If more than one device matches, a connected one wins, then a paired one.
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
    """Builds a BLEDevice so bleak skips the scan, which cannot find a connected keyboard.

    WinRT reads only the address. BlueZ reads `details["path"]` and `details["props"]`.
    """
    from bleak.backends.device import BLEDevice

    try:
        return BLEDevice(address, name, details)
    except TypeError:  # bleak before 1.0 also wants an RSSI
        return BLEDevice(address, name, details, 0)


async def find_device(name: str, address: str | None):
    if sys.platform == "win32":
        address = address or await asyncio.to_thread(find_address, name)
        if not address:
            log_once(f"no paired keyboard named {name!r}; pair it first, or pass --address")
            return None
        return ble_device(address, name, None)

    from bleak.backends.bluezdbus.manager import get_global_bluez_manager

    # This reads BlueZ's object manager. It does not start a scan.
    manager = await get_global_bluez_manager()
    objects = getattr(manager, "_properties", None)
    found = bluez_device(objects, name, address) if isinstance(objects, dict) else None
    if found is None and not isinstance(objects, dict):
        # A bleak version that stores this elsewhere. Build the path from the address.
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
        # The OS connects the keyboard for typing. This helper only joins an existing link.
        log_once("the keyboard is not connected to this computer just now")
        return None
    return ble_device(*found)


async def release(client) -> bool:
    """Lets go of the keyboard without disconnecting it.

    On Linux bleak's disconnect calls Device1.Disconnect, which drops the whole link,
    so this does the rest of it by hand. Returns False if bleak's internals changed.
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
    except Exception as error:  # bleak internals, which can change between versions
        log(f"could not let go of the keyboard cleanly ({describe(error)})")
        return False


# ---- Keyboard link ----


def beside(work) -> asyncio.Task:
    """Starts `work` as a task and logs it if it fails."""

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
    def __init__(self, offer: Offer, crc: int, started: float) -> None:
        self.offer = offer
        # CRC of the OFFER clip, which is what gets ACKed to the keyboard.
        self.crc = crc
        self.started = started
        self.wants = 0
        self.events: asyncio.Queue[tuple] = asyncio.Queue()
        self.task: asyncio.Task | None = None
        # Task repeating HOLD. If the content comes through the keyboard, it
        # keeps running after the fetch ends, until the ACK is sent.
        self.holding: asyncio.Task | None = None


# Results of Bridge.place.
PLACED, FAILED, STALE = "placed", "failed", "stale"


class Bridge:
    """One connection to the keyboard.

    `listen` and `watch` never wait on each other, so a slow clipboard cannot delay an ACK.
    """

    def __init__(self, client, clipboard, name: str, endpoint: Endpoint) -> None:
        self.client = client
        self.clipboard = clipboard
        self.name = name
        self.endpoint = endpoint
        self.assembler = Assembler()
        # Time of the last delivery frame, and whether a complete delivery is still being placed.
        self.delivery_heard = 0.0
        self.accepting = False

        # From the keyboard's STATUS frame.
        self.version = 1
        self.max_length = 4096
        self.max_opaque = 0

        self.incoming: asyncio.Queue[bytes] = asyncio.Queue()
        self.quick_looks = 0
        self.poked = asyncio.Event()

        # Clipboard marker as of the last check.
        self.seen: object = None
        # The last clip sent (fingerprint and owner) and the last one placed here,
        # so neither is sent again just because the marker moved.
        self.sent: tuple[bytes, object] | None = None
        self.placed: bytes | None = None
        # Held across a clipboard write and the marker read after it, so the
        # poll never sees one without the other.
        self.board = asyncio.Lock()
        # Clipboard calls run on worker threads and keep running if their caller
        # is cancelled. This lock stops the next call from starting before then.
        self.board_thread = threading.Lock()

        # Bumped for each clip sent, so a send stops when a newer copy overtakes it.
        self.serial = 0
        self.sending = asyncio.Lock()
        self.pushing: asyncio.Task | None = None

        self.fetch: Fetch | None = None
        # Ticket of a fetch dropped for a local copy. Its content is not placed if it arrives.
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
        """Sends one clip. Returns False if a newer copy overtakes it partway."""
        self.serial += 1
        serial = self.serial
        async with self.sending:
            for frame in transfer(payload, flags, self.frame_cap()):
                if serial != self.serial:
                    return False
                await self.send(frame)
        return True

    async def clear(self) -> None:
        # Drops the keyboard's clip so it never delivers one older than the latest copy here.
        self.serial += 1
        await self.send(bytes([CLEAR]))

    async def relay(self, datagram: bytes) -> None:
        await self.send(bytes([RELAY]) + datagram)

    async def on_board(self, call, *arguments):
        def alone():
            with self.board_thread:
                return call(*arguments)

        return await asyncio.to_thread(alone)

    async def own_addresses(self) -> list[str]:
        """Local addresses, or only the routed ones if a slow host name lookup takes too long."""
        try:
            return await asyncio.wait_for(asyncio.to_thread(self.endpoint.addresses), 0.5)
        except asyncio.TimeoutError:
            return usable(routed_addresses())

    def can_offer(self) -> bool:
        return self.version >= 2 and self.max_opaque >= MIN_OPAQUE

    def busy(self) -> bool:
        """True while a delivery or fetch is in progress. A HELLO then would restart the delivery.

        A delivery only counts while frames keep coming, since the keyboard can drop one silently.
        """
        arriving = (
            self.assembler.active
            and asyncio.get_running_loop().time() - self.delivery_heard < DELIVERY_IDLE_SECONDS
        )
        return self.fetch is not None or arriving or self.accepting

    def same_as_before(self, clip: Clip) -> bool:
        """Whether `clip` was already sent from here or written here.

        Windows bumps its counter when this helper's own read renders a promised format.
        """
        mark = clip.fingerprint()
        return mark == self.placed or (clip.owner is not None and (mark, clip.owner) == self.sent)

    async def check_clipboard(self, poked: bool) -> None:
        async with self.board:
            marker = await self.on_board(self.clipboard.marker, poked)
            if marker == self.seen:
                return
            clip = await self.on_board(self.clipboard.read)
            if clip is None:
                # Another program has the clipboard open. Leave `seen` so the next poll retries.
                return
            self.seen = marker if clip.after is None else clip.after

        # After a copy shortcut, send even if the content is unchanged.
        if not poked and self.same_as_before(clip):
            return
        self.quick_looks = 0
        self.sent = (clip.fingerprint(), clip.owner)
        self.placed = None
        await self.local_copy(clip)

    async def local_copy(self, clip: Clip) -> None:
        """Something was copied here. It replaces any fetch or offer in progress."""
        fetch = self.fetch
        if fetch:
            await self.end_fetch()
            self.abandoned = fetch.offer.ticket
            if fetch.wants:
                # Tell the other computer not to send its content through the keyboard, where it
                # would replace this copy. Sent first, while the keyboard can still route it.
                await self.relay(bytes([CANCEL]) + fetch.offer.ticket)
            await self.send(bytes([HOLD, HOLD_OFF]))
            log("stopped fetching: something was copied here")

        # Only the latest copy is ever on offer.
        self.endpoint.offering = None
        await gone(self.answering)
        await gone(self.pushing)
        self.pushing = beside(self.push(clip))

    async def push(self, clip: Clip) -> None:
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
        """Puts a copy on offer and sends the OFFER through the keyboard."""
        offering = Offering(kind, produce)
        # Even with no listening port, the OFFER goes out so the other helper
        # can ask for the copy with a WANT.
        port = self.endpoint.port
        addresses = await self.own_addresses() if port else []
        message = Offer(kind, offering.ticket, offering.key, port, addresses).encode(self.max_opaque)
        self.endpoint.offering = offering
        log(f"offering {what} to the next computer")
        await self.send_clip(message, keyboard_on_usb(self.name) | OPAQUE)

    async def answer(self, offering: Offering, port: int, addresses: list[str]) -> None:
        """Sends the offered copy to a helper that could not fetch it, by PUT or else as an INLINE."""
        try:
            content = await offering.content()
        except Exception as error:  # Pillow can raise many error types on a bad image
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
        if not datagram:
            return
        ticket = datagram[1:9]
        offering = self.endpoint.offering

        if datagram[0] == GONE and len(datagram) >= 9:
            if self.fetch and ticket == self.fetch.offer.ticket:
                self.fetch.events.put_nowait(("gone",))
            return

        if datagram[0] == CANCEL and len(datagram) >= 9:
            # The asking computer has a newer copy. An INLINE now would replace it in the keyboard.
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
            # Something newer was copied here. GONE saves the other helper a long wait.
            await self.relay(bytes([GONE]) + ticket)
            return
        if self.answering and not self.answering.done():
            return
        self.answering = beside(self.answer(offering, port, addresses))

    async def place(
        self, kind: int, content: bytes, crc: int, how: str, holding: asyncio.Task | None = None
    ) -> str:
        """Puts delivered content on the clipboard and ACKs it.

        `holding` (the HOLD task, if any) runs until the ACK goes out, since writing
        an image can be slow. A HOLD after the ACK would hold pastes again.
        """
        try:
            async with self.board:
                # A copy made here since the last check is newer and must not be
                # overwritten. Before the first check there is nothing to compare.
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
                except Exception as error:  # Pillow can raise many error types on a bad image
                    log(f"could not make sense of what arrived ({describe(error)})")
                    written = False
                if not written:
                    log("could not set the clipboard")
                    return FAILED

                await gone(holding)
                holding = None
                # The ACK tells the keyboard to let the paste through instead of typing the clip.
                await self.send(bytes([ACK]) + crc.to_bytes(4, "little"))
                self.placed = mark
                log(how.format(len(content)))
                await asyncio.sleep(0.1)  # let the clipboard settle before reading its marker
                # Not a fresh look, since looking can be costly. If the marker
                # moves later, same_as_before still recognizes this clip.
                self.seen = await self.on_board(self.clipboard.marker, False)
                return PLACED
        finally:
            if holding is not None:
                holding.cancel()

    async def accept(self, payload: bytes, crc: int, flags: int) -> None:
        if not flags & OPAQUE:
            # Plain text replaces any fetch in progress.
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
            # Nothing is left to fetch. Any HOLD repeats keep going until this is placed.
            holding = await self.end_fetch(keep_holding=True)
            if ticket == self.abandoned:
                # This was asked for before a newer local copy. ACK it anyway so pastes are not held.
                await gone(holding)
                await self.send(bytes([ACK]) + crc.to_bytes(4, "little"))
                return
            await self.place(kind, content, crc, "took delivery of {} bytes through the keyboard", holding)
        else:
            # From a newer helper version. ACK it anyway so a paste here is not kept waiting.
            await self.end_fetch()
            await self.send(bytes([ACK]) + crc.to_bytes(4, "little"))
            log("the other computer sent something this version cannot read")

    def start_fetch(self, offer: Offer, crc: int) -> None:
        fetch = Fetch(offer, crc, asyncio.get_running_loop().time())
        self.fetch = fetch
        fetch.holding = beside(self.keep_holding(fetch))
        fetch.task = beside(self.run_fetch(fetch))

    async def keep_holding(self, fetch: Fetch) -> None:
        """Repeats HOLD so a paste waits for the fetch instead of pasting the old clipboard.

        Once the fast network routes have had their time, it tells the keyboard to drop pastes.
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
        try:
            found = await self.find(fetch)

            outcome = FAILED
            if isinstance(found, tuple):
                outcome = await self.place(*found, fetch.holding)
            else:
                log(f"could not fetch what was copied on the other computer: {found}")
            await gone(fetch.holding)

            if outcome == STALE:
                # Something was copied here meanwhile and the watch loop sends it, so only end the HOLD.
                await self.send(bytes([HOLD, HOLD_OFF]))
            elif outcome == FAILED:
                await self.send(bytes([HOLD, HOLD_OFF]))
                await self.send(bytes([ACK]) + fetch.crc.to_bytes(4, "little"))
        except asyncio.CancelledError:
            # Cancelled by end_fetch, which decides what happens to the HOLD task.
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
        """Tries each route in turn. Returns the arguments for `place`, or a failure reason string.

        An INLINE arrives as a normal clip instead, and `accept` ends the fetch.
        """
        offer = fetch.offer

        content = await self.endpoint.get(offer)
        if content is not None:
            return offer.kind, content, fetch.crc, "fetched {} bytes over the network"

        # GET failed. Ask the other helper to PUT it here, or else to send it
        # as an INLINE through the keyboard.
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
                # The WANT may have been too long for the other end's link.
                # Retry once with no addresses, the shortest form.
                fetch.wants += 1
                await self.relay(encode_want(offer.ticket, port, [], room))

    async def end_fetch(self, keep_holding: bool = False) -> asyncio.Task | None:
        """Stops fetching silently. With `keep_holding`, returns the HOLD task for the caller to stop at the ACK."""
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

    async def handle(self, frame: bytes) -> None:
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
            # The keyboard saw a copy shortcut. Checking right away lets a quick
            # switch-and-paste carry the new clip.
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
            # The keyboard counts it as still being delivered until it is ACKed.
            self.accepting = True
            try:
                await self.accept(*clip)
            finally:
                self.accepting = False
        elif kind == RELAY:
            await self.on_relay(frame[1:])

    async def listen(self) -> None:
        while True:
            await self.handle(await self.incoming.get())

    async def watch(self) -> None:
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

            # The firmware stops waiting on a helper that misses an ACK. A HELLO
            # makes it trust the helper again.
            if loop.time() - said_hello >= HELLO_SECONDS and not self.busy():
                said_hello = loop.time()
                await self.send(bytes([HELLO, VERSION, 0]))

    async def run(self) -> None:
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
        await self.end_fetch()
        await gone(self.answering)
        await gone(self.pushing)


async def session(client, clipboard, name: str, endpoint: Endpoint) -> None:
    """Runs one connection. Errors are logged and not raised, so they never stop the helper."""
    bridge = Bridge(client, clipboard, name, endpoint)
    try:
        await bridge.run()
    except Exception as error:
        log(f"link lost ({describe(error)})")
    finally:
        try:
            await bridge.close()
            if client.is_connected:
                # So the next paste here does not wait for an ACK that will never come.
                await bridge.send(bytes([BYE]))
        except Exception:
            pass


async def attempt(
    args: argparse.Namespace, clipboard, endpoint: Endpoint, state: dict, find=None, make_client=None
) -> None:
    if make_client is None:
        from bleak import BleakClient as make_client

    device = await (find or find_device)(args.name, args.address)
    if device is None:
        return

    options = {}
    if sys.platform == "win32":
        # Windows caches a paired device's services, and a cache from before the
        # firmware had the clipboard service would hide it. Windows also sometimes
        # needs the address type, so each type is tried in turn until one works.
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
            # Stopped while connecting. On Linux a cancelled connect makes bleak
            # disconnect the keyboard, so let it finish and then release it.
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
        # Release first, then leave the keyboard alone for a while.
        await asyncio.sleep(UNSUPPORTED_SECONDS)


async def serve(args: argparse.Namespace, clipboard, endpoint: Endpoint, state: dict, once=attempt) -> None:
    while True:
        try:
            await once(args, clipboard, endpoint, state)
        except Exception as error:  # only a stop signal ends the helper
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

    # Use signal handlers instead of KeyboardInterrupt so shutdown is orderly, and on
    # Linux nothing cancels the bleak task that would drop the keyboard's link.
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
        # bleak could not release the keyboard. A normal event loop shutdown
        # would cancel bleak's task that disconnects the keyboard, so exit now.
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
