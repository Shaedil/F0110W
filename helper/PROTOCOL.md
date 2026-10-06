# How the helpers pass each other what the keyboard cannot carry

The keyboard carries text. An image, or text longer than it holds, goes from
the helper on one computer to the helper on the other, and the keyboard only
carries a short message saying where to fetch it. This is what the two helpers
agree on: M0110HUD on a Mac, `m0110_clipboard.py` on Windows and Linux.

The frames between a helper and the keyboard are in the firmware's
`config/clipboard/clip_proto.h`. What matters from there:

- An **opaque clip** is a clip sent with `CLIP_FLAG_OPAQUE`. The keyboard holds
  it like text, hands it only to a helper, and never types it.
- **RELAY** carries a datagram of up to 63 bytes to the helper at the other end
  of the clip. If there is none, the sender gets `RESULT` with code 3.
- **HOLD** asks the keyboard to keep pastes back while this helper fetches.
- All of it needs `STATUS` to report version 2 or later and a `max_opaque` of
  at least 256, which is room for an OFFER with every address. Against older
  firmware a helper carries text only, as before.

*Source* below is the computer the copy was made on, *receiver* the one the
keyboard was switched to. Multi-byte fields are little-endian.

## What is carried

| On the clipboard | Sent as |
| --- | --- |
| Marked private by a password manager | nothing; `CLEAR` |
| Text of at most `max_len` bytes | a text clip, as always |
| Longer text | an OFFER of kind 1 |
| An image and no text | an OFFER of kind 2 or 3 |
| Neither | nothing; `CLEAR` |

Text wins when both are present, because that is what a copy from a document or
a spreadsheet means. The exception is an image copied in a browser, where the
text is only the image's address: there the image wins.

Content kinds: `1` UTF-8 text with LF line endings, `2` PNG, `3` JPEG.

## Messages

An opaque clip holds one of:

```
OFFER   01 kind id[8] key[32] port:u16 count { family addr }*
INLINE  02 kind id[8] content...
```

A RELAY datagram holds one of:

```
WANT    01 id[8] port:u16 count { family addr }*
GONE    02 id[8]
CANCEL  03 id[8]
```

WANT and CANCEL go from the receiver to the source, GONE the other way.

`id` names one copy and is random. `key` is 32 random bytes, used for that copy
only. `family` is `4` or `6`, followed by 4 or 16 address bytes. `port` is the
TCP port the sender listens on. A WANT may have a count of zero.

Addresses offered are the computer's own, on every interface that is up,
leaving out loopback and link-local ones. A helper puts in as many as fit:
IPv4 first, and never more than 6.

## The stream

Each helper listens on one TCP port, on every interface. Whichever side
connects says what it is connecting for:

```
"M0CB" 01 role id[8]        role 1 = GET, send me that copy
                            role 2 = PUT, here is that copy
```

The content then flows from the source to the receiver as records:

```
last:u8 n:u32 sealed[n]
```

`sealed` is ChaCha20-Poly1305 under `key` of up to 65536 bytes of content,
with the 16-byte tag at the end, so `n` is at most 65552. The nonce is four
zero bytes followed by the record's number as a u64, counting from zero. The
associated data is `id` followed by the `last` byte. `last` is `1` on the final
record and `0` on the others; empty content is one final record sealing
nothing.

When it has opened the final record the receiver sends back the single byte
`01` and closes the connection. Only then does the source count the content as
taken: a connection that closes without it, for whatever reason, did not take
it. Either side gives up on a stream that makes no progress for 10 seconds.

A listener asked for a copy it is not offering, or handed one it did not ask
for, closes the connection. A record that does not open, a stream that ends
before its final record, or content past 256 MiB fails the fetch. Nothing
readable crosses the network without the key, and the key only ever travels
through the keyboard, whose link is encrypted and bonded.

### Vectors

With `id` = `00 01 .. 07` and `key` = `10 11 .. 2f`:

- OFFER of a PNG on port 51234 at 192.168.1.20 and fd00::1234:
  `01020001020304050607101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f22c80204c0a8011406fd000000000000000000000000001234`
- WANT on port 40000 at 10.0.0.7: `010001020304050607409c01040a000007`
- The content `hello, world` as two records, `hello, ` then `world`:
  `0017000000607f787e815ec174019f43e6bffb11c2ecfbffa81efddf`
  `0115000000100a35e63e77753531f04ac52596a7a96c6b099f1d`
- Empty content: `0110000000570bfcee544eff0e3cf8e15b02478f22`

## The source

On a copy that calls for an OFFER, the source makes an `id` and a `key`, keeps
the content, and sends the OFFER as an opaque clip. It keeps only the latest
copy: the next one, of any kind, replaces it.

- **GET** for the current `id`: stream the content.
- **WANT** for the current `id`: connect to each address in it at once, PUT on
  the first that answers within 1 second, and stream the content. If none
  answers, or there were none, send an INLINE as a new opaque clip. If the
  content cannot be made to fit, send GONE.
- **WANT** for any other `id`: send GONE. Something has been copied since.
- A WANT that arrives while the last one is still being answered is ignored.
- **CANCEL** for the current `id`: stop offering it and send nothing more for
  it. Something newer has been copied on the computer that asked, and an
  INLINE now would replace that in the keyboard.

An INLINE holds the content cut down to fit: the whole message is at most
the smaller of `max_opaque` and 40000 bytes. Text either fits or it does not.
An image is scaled down and re-encoded as JPEG until it does.

## The receiver

On delivery of an OFFER:

1. Send `HOLD` with `SOON`, and again every 400 ms for as long as the fetch
   runs. From 2.5 seconds in, send it without `SOON`: whatever is still going
   on by then is not worth holding a paste for.
2. Connect to every address in the OFFER at once. GET on the first that
   answers within 1 second, read the content, put it on the clipboard, and
   `ACK` the OFFER's checksum. Done.
3. If none answers, or the stream from the one that did fails, RELAY a WANT with this helper's own port and addresses, as
   many as fit in the frame. If the keyboard answers that it could not be
   passed on, send one more with no addresses, which always fits. If that
   cannot be passed on either, give up.
4. For 1.5 seconds, wait for a PUT. If one comes, read the content, put it on
   the clipboard, and `ACK` the OFFER's checksum. Done.
5. Wait up to 90 seconds more for an INLINE to be delivered. Put its content on the clipboard and `ACK` that
   clip's checksum. Done. A PUT that turns up late is still taken.
6. On GONE, or when the wait runs out, give up.

Giving up is `HOLD` with `OFF`, then an `ACK` of the OFFER's checksum, which
tells the keyboard there is nothing more to wait for and lets a paste through
as the computer's own. The `HOLD` repeats stop before any `ACK` is sent: the
keyboard would take one that followed it as a new request.

When something is copied on the receiver itself the fetch is abandoned: a
CANCEL if a WANT has been sent, then `HOLD` `OFF`, both ahead of the frames of
the new copy. An INLINE for that `id` that arrives all the same is
acknowledged and not put on the clipboard. The fetch is abandoned silently
when a different clip is delivered or the link drops.

Any other INLINE is put on the clipboard and acknowledged whatever its `id`
and whether or not a fetch is running: it is the latest copy either way. An
opaque clip that cannot be read at all is acknowledged too, so that a paste is
not kept waiting on it.

While a clip is being delivered or a fetch is running, a helper does not send
its periodic `HELLO`: the keyboard takes a `HELLO` to mean a helper that has
only just started, and would begin the delivery again.
