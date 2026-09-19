# AwoX/Telink Protocol

## Scope

The app implements the legacy Telink private-mesh protocol used by compatible
AwoX lights. Compatibility is determined by successful characteristic
discovery and authentication, not by the advertised product name alone.

The implementation is informed by Telink's legacy
[`telink_private_mesh`](https://github.com/telink-semi/telink_private_mesh)
SDK. This document describes the behavior implemented here; it is not a general
specification for every AwoX product generation.

## Discovery

The app scans without a service filter. A candidate must advertise at least
eight bytes of manufacturer data. Its six-byte protocol address is constructed
from two leading zero bytes followed by bytes 4 through 7 in reverse order.

After connecting, all services and characteristics are discovered. Required
characteristics are identified by UUID suffix:

| Suffix | Role |
| --- | --- |
| `0D1911` | Status notification and status request setup |
| `0D1912` | Encrypted command writes |
| `0D1914` | Authentication request and response |

## Authentication

Each connection creates a fresh eight-byte cryptographic random value.
`AwoXCrypto.makePairPacket` pads the UTF-8 mesh name and password to 16 bytes,
XORs them, AES-encrypts the result with the random value padded to 16 bytes,
and emits the `0x0c` pairing request.

A valid response begins with `0x0d` and supplies an eight-byte response random
value. The session key is AES-128 encryption of both random values using the
XORed mesh credentials. Keys and AES blocks are reversed around CommonCrypto to
match the protocol's byte order.

Mesh names and passwords must each fit within 16 UTF-8 bytes. Session material
is held only in memory and reset when an operation finishes or fails.

## Commands

Encrypted command packets contain a random three-byte sequence, a two-byte
checksum, and an encrypted 15-byte payload. The destination is the last mesh ID
reported by the light, or broadcast `0xffff` before a status is known.

| Action | Opcode | Parameters |
| --- | --- | --- |
| Power | `0xd0` | `1,0,0` for on; `0,0,0` for off |
| White brightness | `0xf1` | Percentage `1...100` |
| Color brightness | `0xf2` | Percentage `1...100` |
| RGB color | `0xe2` | `0x04,r,g,b` |
| Status request | `0xda` | `0x10` |

After a control write succeeds, the app waits briefly and performs a status
request. The status characteristic first receives `0x01`; the encrypted status
request is then written to the command characteristic. A four-second timeout
fails the active operation.

## Status

The decrypted status packet must be exactly 20 bytes and contain `0xdc,0x60,
0x01` at offsets 7 through 9. The parser extracts:

- Mesh ID and online state.
- Power and white/RGB mode bits.
- White brightness and temperature.
- Color brightness and RGB channels.

Do not alter offsets, byte order, nonces, checksum construction, or opcodes
without a captured fixture or physical-device validation. Never commit packet
captures containing identifiers or credentials.
