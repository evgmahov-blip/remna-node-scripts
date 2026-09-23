"""HKDF-SHA256 and TLS 1.3 HKDF-Expand-Label (RFC 5869, RFC 8446)."""

from __future__ import annotations

import hashlib
import hmac


def hmac_sha256(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    if salt is None:
        salt = b""
    if len(salt) == 0:
        salt = b"\x00" * 32
    return hmac_sha256(salt, ikm)


def hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes:
    if length > 255 * 32:
        raise ValueError("hkdf length too large")
    okm = b""
    previous = b""
    counter = 1
    while len(okm) < length:
        previous = hmac_sha256(prk, previous + info + bytes([counter]))
        okm += previous
        counter += 1
    return okm[:length]


def hkdf_expand_label(secret: bytes, label: str, context: bytes, length: int) -> bytes:
    full = b"tls13 " + label.encode("ascii")
    if len(full) > 255 or len(context) > 255:
        raise ValueError("label or context too long")
    hkdf_label = (
        length.to_bytes(2, "big")
        + bytes([len(full)])
        + full
        + bytes([len(context)])
        + context
    )
    return hkdf_expand(secret, hkdf_label, length)
