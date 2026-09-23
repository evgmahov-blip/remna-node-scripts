"""X25519 (RFC 7748) using integer arithmetic. No external crypto library."""

from __future__ import annotations

import os

P = 2**255 - 19
A24 = 121665


def _decode_scalar(scalar: bytes) -> int:
    if len(scalar) != 32:
        raise ValueError("X25519 scalar must be 32 bytes")
    clamped = bytearray(scalar)
    clamped[0] &= 248
    clamped[31] &= 127
    clamped[31] |= 64
    return int.from_bytes(clamped, "little")


def _decode_u(u_bytes: bytes) -> int:
    if len(u_bytes) != 32:
        raise ValueError("X25519 u-coordinate must be 32 bytes")
    value = int.from_bytes(u_bytes, "little")
    return value & ((1 << 255) - 1)


def _encode_u(value: int) -> bytes:
    return (value % P).to_bytes(32, "little")


def x25519(scalar: bytes, peer: bytes) -> bytes:
    k = _decode_scalar(scalar)
    u = _decode_u(peer)
    x1 = u
    x2, z2 = 1, 0
    x3, z3 = u, 1
    swap = 0
    for bit in range(254, -1, -1):
        kt = (k >> bit) & 1
        swap ^= kt
        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        swap = kt
        a = (x2 + z2) % P
        aa = (a * a) % P
        b = (x2 - z2) % P
        bb = (b * b) % P
        e = (aa - bb) % P
        c = (x3 + z3) % P
        d = (x3 - z3) % P
        da = (d * a) % P
        cb = (c * b) % P
        x3 = pow(da + cb, 2, P)
        z3 = (x1 * pow(da - cb, 2, P)) % P
        x2 = (aa * bb) % P
        z2 = (e * (aa + A24 * e)) % P
    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2
    return _encode_u((x2 * pow(z2, P - 2, P)) % P)


def generate_private_key(rng: bytes | None = None) -> bytes:
    raw = rng if rng is not None else os.urandom(32)
    if len(raw) != 32:
        raise ValueError("private key entropy must be 32 bytes")
    return bytes(raw)


def public_key(private: bytes) -> bytes:
    return x25519(private, bytes([9]) + b"\x00" * 31)


def shared_secret(private: bytes, peer_public: bytes) -> bytes:
    return x25519(private, peer_public)
