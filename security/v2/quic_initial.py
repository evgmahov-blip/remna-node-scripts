"""QUIC v1 Initial packets (RFC 9000 / RFC 9001) for offline noise fixtures.

The wireguard -> dialerProxy -> freedom noise shape is an independent
reimplementation of the reviewed idea. This module does not claim that a
packet is undetectable or that it bypasses any network.

Profile structure is stable for a profile version. Random, key share, connection
IDs and packet number change per generation.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass

from security.v2.crypto_aes import aes128_encrypt_block, aes128_gcm_decrypt, aes128_gcm_encrypt
from security.v2.hkdf import hkdf_expand_label, hkdf_extract
from security.v2.x25519 import generate_private_key, public_key

INITIAL_SALT = bytes.fromhex("38762cf7f55934b34d179ae6a4c80cadccbb7f0a")
QUIC_V1 = b"\x00\x00\x00\x01"

# RFC 9001 appendix A.1, DCID 8394c8f03e515708.
RFC9001_INITIAL_SECRET = bytes.fromhex(
    "7db5df06e7a69e432496adedb00851923595221596ae2ae9fb8115c1e9ed0a44"
)
RFC9001_CLIENT_INITIAL_SECRET = bytes.fromhex(
    "c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea"
)
RFC9001_CLIENT_KEY = bytes.fromhex("1f369613dd76d5467730efcbe3b1a22d")
RFC9001_CLIENT_IV = bytes.fromhex("fa044b2f42a3fd3b46fb255c")
RFC9001_CLIENT_HP = bytes.fromhex("9f50449e04a0e810283a1e9933adedd2")


def initial_secrets(dcid: bytes) -> dict[str, bytes]:
    initial = hkdf_extract(INITIAL_SALT, dcid)
    client = hkdf_expand_label(initial, "client in", b"", 32)
    return {
        "initial_secret": initial,
        "client_initial_secret": client,
        "key": hkdf_expand_label(client, "quic key", b"", 16),
        "iv": hkdf_expand_label(client, "quic iv", b"", 12),
        "hp": hkdf_expand_label(client, "quic hp", b"", 16),
    }


def quic_varint(value: int, width: int | None = None) -> bytes:
    if value < 0:
        raise ValueError("varint must be non-negative")
    if width is None:
        if value < 2**6:
            width = 1
        elif value < 2**14:
            width = 2
        elif value < 2**30:
            width = 4
        else:
            width = 8
    if width == 1:
        if value > 63:
            raise ValueError("varint does not fit in 1 byte")
        return bytes([value])
    if width == 2:
        if value > 16383:
            raise ValueError("varint does not fit in 2 bytes")
        return (value | 0x4000).to_bytes(2, "big")
    if width == 4:
        if value > 1073741823:
            raise ValueError("varint does not fit in 4 bytes")
        return (value | 0x80000000).to_bytes(4, "big")
    if width == 8:
        return (value | 0xC000000000000000).to_bytes(8, "big")
    raise ValueError("unsupported varint width")


def _ext(ext_type: int, body: bytes) -> bytes:
    return ext_type.to_bytes(2, "big") + len(body).to_bytes(2, "big") + body


def build_client_hello(profile: dict, random32: bytes, session_id: bytes, keyshare: bytes) -> bytes:
    if len(random32) != 32 or len(session_id) != 32 or len(keyshare) != 32:
        raise ValueError("ClientHello random, session id and key share must be 32 bytes")
    sni = profile["sni"].encode("ascii")
    sni_body = len(sni).to_bytes(2, "big") + b"\x00" + len(sni).to_bytes(2, "big") + sni
    sni_list = len(sni_body).to_bytes(2, "big") + sni_body
    groups = b"".join(int(g).to_bytes(2, "big") for g in profile["groups"])
    groups_body = len(groups).to_bytes(2, "big") + groups
    sigs = b"".join(int(s).to_bytes(2, "big") for s in profile["signature_algorithms"])
    sigs_body = len(sigs).to_bytes(2, "big") + sigs
    versions = b"".join(bytes.fromhex(v) for v in profile["supported_versions"])
    versions_body = bytes([len(versions)]) + versions
    share = b"\x00\x1d" + len(keyshare).to_bytes(2, "big") + keyshare
    share_body = len(share).to_bytes(2, "big") + share
    alpn_items = b""
    for name in profile["alpn"]:
        raw = name.encode("ascii")
        alpn_items += bytes([len(raw)]) + raw
    alpn_body = len(alpn_items).to_bytes(2, "big") + alpn_items
    builders = {
        "server_name": _ext(0x0000, sni_list),
        "supported_groups": _ext(0x000A, groups_body),
        "signature_algorithms": _ext(0x000D, sigs_body),
        "supported_versions": _ext(0x002B, versions_body),
        "key_share": _ext(0x0033, share_body),
        "alpn": _ext(0x0010, alpn_body),
        "psk_key_exchange_modes": _ext(0x002D, bytes([1, profile["psk_mode"]])),
    }
    extensions = b"".join(builders[name] for name in profile["extension_order"])
    ciphers = b"".join(int(c).to_bytes(2, "big") for c in profile["cipher_suites"])
    body = b"\x03\x03" + random32
    body += bytes([len(session_id)]) + session_id
    body += len(ciphers).to_bytes(2, "big") + ciphers
    body += b"\x01\x00"
    body += len(extensions).to_bytes(2, "big") + extensions
    return b"\x01" + len(body).to_bytes(3, "big") + body


def crypto_frame(handshake: bytes) -> bytes:
    return b"\x06" + quic_varint(0, 1) + quic_varint(len(handshake), 2) + handshake


@dataclass(frozen=True)
class ParsedInitial:
    dcid: bytes
    scid: bytes
    packet_number: int
    payload: bytes
    client_hello: bytes


def _header(dcid: bytes, scid: bytes, pn: int, payload_len: int, pn_len: int = 4) -> tuple[bytes, int]:
    first = 0xC0 | (pn_len - 1)
    length = pn_len + payload_len
    header = bytes([first]) + QUIC_V1
    header += bytes([len(dcid)]) + dcid
    header += bytes([len(scid)]) + scid
    header += quic_varint(0, 1)
    header += quic_varint(length, 2)
    pn_offset = len(header)
    header += pn.to_bytes(pn_len, "big")
    return header, pn_offset


def _protect_header(packet: bytearray, pn_offset: int, hp_key: bytes, pn_len: int) -> None:
    sample = bytes(packet[pn_offset + 4 : pn_offset + 20])
    if len(sample) != 16:
        raise ValueError("not enough bytes for header protection sample")
    mask = aes128_encrypt_block(hp_key, sample)
    packet[0] ^= mask[0] & 0x0F
    for i in range(pn_len):
        packet[pn_offset + i] ^= mask[1 + i]


def _unprotect_header(packet: bytearray, pn_offset: int, hp_key: bytes) -> int:
    sample = bytes(packet[pn_offset + 4 : pn_offset + 20])
    mask = aes128_encrypt_block(hp_key, sample)
    packet[0] ^= mask[0] & 0x0F
    pn_len = (packet[0] & 0x03) + 1
    for i in range(pn_len):
        packet[pn_offset + i] ^= mask[1 + i]
    return pn_len


def profile_content_hash(profile: dict) -> str:
    canonical = json.dumps(profile, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def generate_initial(profile: dict, *, packet_size: int, seed: bytes) -> bytes:
    """Build one protected Initial datagram.

    seed is 32-byte entropy mixed into the per-generation fields. The same
    profile definition yields the same structural layout.
    """
    if len(seed) < 32:
        raise ValueError("seed must be at least 32 bytes")
    if packet_size < 200 or packet_size > 1350:
        raise ValueError("packet size must be between 200 and 1350")
    dcid_len = int(profile["dcid_len"])
    scid_len = int(profile["scid_len"])
    dcid = hashlib.sha256(b"dcid" + seed).digest()[:dcid_len]
    scid = hashlib.sha256(b"scid" + seed).digest()[:scid_len]
    random32 = hashlib.sha256(b"rnd" + seed).digest()
    session_id = hashlib.sha256(b"sid" + seed).digest()
    pn = int.from_bytes(hashlib.sha256(b"pn" + seed).digest()[:4], "big") & 0xFFFFFFFF
    priv = generate_private_key(hashlib.sha256(b"x25519" + seed).digest())
    share = public_key(priv)
    hello = build_client_hello(profile, random32, session_id, share)
    frame = crypto_frame(hello)
    secrets = initial_secrets(dcid)
    # Header length with a 4-byte packet number and a 2-byte length varint.
    header_len = 1 + 4 + 1 + dcid_len + 1 + scid_len + 1 + 2 + 4
    overhead = header_len + 16
    if packet_size < overhead + len(frame):
        raise ValueError("packet size smaller than ClientHello frame")
    plaintext = frame + b"\x00" * (packet_size - overhead - len(frame))
    header, pn_offset = _header(dcid, scid, pn, len(plaintext) + 16)
    if len(header) != header_len:
        raise RuntimeError(f"header length drifted: {len(header)} != {header_len}")
    nonce = bytes(a ^ b for a, b in zip(secrets["iv"], b"\x00" * 8 + pn.to_bytes(4, "big")))
    ciphertext, tag = aes128_gcm_encrypt(secrets["key"], nonce, plaintext, header)
    packet = bytearray(header + ciphertext + tag)
    _protect_header(packet, pn_offset, secrets["hp"], 4)
    if len(packet) != packet_size:
        raise RuntimeError("packet size mismatch")
    return bytes(packet)


def parse_initial(packet: bytes) -> ParsedInitial:
    raw = bytearray(packet)
    if len(raw) < 32 or raw[1:5] != bytearray(QUIC_V1):
        # Version is not header-protected. Long-header fixed bit may be masked
        # only in the low nibble, so version still sits at bytes 1..4.
        raise ValueError("not a QUIC v1 long header")
    offset = 5
    dcid_len = raw[offset]
    offset += 1
    dcid = bytes(raw[offset : offset + dcid_len])
    offset += dcid_len
    scid_len = raw[offset]
    offset += 1
    scid = bytes(raw[offset : offset + scid_len])
    offset += scid_len
    if raw[offset] != 0:
        raise ValueError("non-empty Initial token is not used by this profile")
    offset += 1
    length = int.from_bytes(raw[offset : offset + 2], "big") & 0x3FFF
    offset += 2
    pn_offset = offset
    secrets = initial_secrets(dcid)
    pn_len = _unprotect_header(raw, pn_offset, secrets["hp"])
    if (raw[0] & 0xF0) != 0xC0:
        raise ValueError("unprotected header is not an Initial")
    pn = int.from_bytes(raw[pn_offset : pn_offset + pn_len], "big")
    body = bytes(raw[pn_offset + pn_len : pn_offset + length])
    if len(body) < 16:
        raise ValueError("protected payload too short")
    ciphertext, tag = body[:-16], body[-16:]
    aad = bytes(raw[: pn_offset + pn_len])
    nonce = bytes(a ^ b for a, b in zip(secrets["iv"], b"\x00" * (12 - pn_len) + pn.to_bytes(pn_len, "big")))
    payload = aes128_gcm_decrypt(secrets["key"], nonce, ciphertext, aad, tag)
    if not payload.startswith(b"\x06"):
        raise ValueError("payload does not start with a CRYPTO frame")
    # offset varint is 1 byte and length varint is 2 bytes for this builder.
    hello_len = int.from_bytes(payload[2:4], "big") & 0x3FFF
    hello = payload[4 : 4 + hello_len]
    if not hello.startswith(b"\x01"):
        raise ValueError("CRYPTO payload is not a ClientHello")
    return ParsedInitial(dcid=dcid, scid=scid, packet_number=pn, payload=payload, client_hello=hello)


def client_hello_invariants(hello: bytes, profile: dict) -> dict:
    if hello[0] != 1:
        raise ValueError("not a ClientHello")
    # Skip handshake header (4) + legacy version (2) + random (32).
    pos = 4 + 2 + 32
    sid_len = hello[pos]
    pos += 1 + sid_len
    cs_len = int.from_bytes(hello[pos : pos + 2], "big")
    pos += 2
    ciphers = hello[pos : pos + cs_len]
    pos += cs_len
    comp_len = hello[pos]
    pos += 1 + comp_len
    ext_len = int.from_bytes(hello[pos : pos + 2], "big")
    pos += 2
    end = pos + ext_len
    types = []
    alpn = b""
    while pos + 4 <= end:
        et = int.from_bytes(hello[pos : pos + 2], "big")
        el = int.from_bytes(hello[pos + 2 : pos + 4], "big")
        body = hello[pos + 4 : pos + 4 + el]
        types.append(et)
        if et == 0x0010:
            alpn = body
        pos += 4 + el
    expected = {
        "server_name": 0x0000,
        "supported_groups": 0x000A,
        "signature_algorithms": 0x000D,
        "supported_versions": 0x002B,
        "key_share": 0x0033,
        "alpn": 0x0010,
        "psk_key_exchange_modes": 0x002D,
    }
    expect_types = [expected[name] for name in profile["extension_order"]]
    return {
        "ciphers": ciphers,
        "extension_types": types,
        "expected_extension_types": expect_types,
        "alpn": alpn,
        "legacy_version": hello[4:6],
    }
