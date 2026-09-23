"""AES-128 and AES-GCM (96-bit nonce) from FIPS 197 and NIST SP 800-38D.

Independent implementation used for QUIC Initial packet protection. No third-party
crypto package is required, so offline CI stays network-free.
"""

from __future__ import annotations

SBOX = (
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
)

RCON = (0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36)


def _xtime(value: int) -> int:
    value <<= 1
    if value & 0x100:
        value ^= 0x1B
    return value & 0xFF


def _expand_key(key: bytes) -> list[list[int]]:
    if len(key) != 16:
        raise ValueError("AES-128 key must be 16 bytes")
    words = [list(key[i : i + 4]) for i in range(0, 16, 4)]
    for index in range(4, 44):
        temp = words[index - 1][:]
        if index % 4 == 0:
            temp = temp[1:] + temp[:1]
            temp = [SBOX[b] for b in temp]
            temp[0] ^= RCON[index // 4]
        words.append([a ^ b for a, b in zip(words[index - 4], temp)])
    rounds = []
    for round_index in range(11):
        block = []
        for word in words[round_index * 4 : round_index * 4 + 4]:
            block.extend(word)
        rounds.append(block)
    return rounds


def _add_round_key(state: list[int], round_key: list[int]) -> None:
    for i, value in enumerate(round_key):
        state[i] ^= value


def _sub_bytes(state: list[int]) -> None:
    for i, value in enumerate(state):
        state[i] = SBOX[value]


def _shift_rows(state: list[int]) -> None:
    # Column-major state: index = row + 4*col.
    for row in range(1, 4):
        cells = [state[row + 4 * col] for col in range(4)]
        cells = cells[row:] + cells[:row]
        for col, value in enumerate(cells):
            state[row + 4 * col] = value


def _mix_columns(state: list[int]) -> None:
    for col in range(4):
        i = 4 * col
        a, b, c, d = state[i : i + 4]
        state[i] = _xtime(a) ^ _xtime(b) ^ b ^ c ^ d
        state[i + 1] = a ^ _xtime(b) ^ _xtime(c) ^ c ^ d
        state[i + 2] = a ^ b ^ _xtime(c) ^ _xtime(d) ^ d
        state[i + 3] = _xtime(a) ^ a ^ b ^ c ^ _xtime(d)


def aes128_encrypt_block(key: bytes, block: bytes) -> bytes:
    if len(block) != 16:
        raise ValueError("AES block must be 16 bytes")
    rounds = _expand_key(key)
    state = list(block)
    _add_round_key(state, rounds[0])
    for round_key in rounds[1:-1]:
        _sub_bytes(state)
        _shift_rows(state)
        _mix_columns(state)
        _add_round_key(state, round_key)
    _sub_bytes(state)
    _shift_rows(state)
    _add_round_key(state, rounds[-1])
    return bytes(state)


def _xor(left: bytes, right: bytes) -> bytes:
    return bytes(a ^ b for a, b in zip(left, right))


def _gcm_mul(x: int, y: int) -> int:
    z = 0
    v = x
    for i in range(128):
        if (y >> (127 - i)) & 1:
            z ^= v
        if v & 1:
            v = (v >> 1) ^ 0xE1000000000000000000000000000000
        else:
            v >>= 1
        v &= (1 << 128) - 1
    return z & ((1 << 128) - 1)


def _ghash(hash_key: bytes, aad: bytes, ciphertext: bytes) -> bytes:
    h_int = int.from_bytes(hash_key, "big")
    y = 0

    def absorb(buf: bytes) -> None:
        nonlocal y
        padded = buf + b"\x00" * ((-len(buf)) % 16)
        for offset in range(0, len(padded), 16):
            block = int.from_bytes(padded[offset : offset + 16], "big")
            y = _gcm_mul(y ^ block, h_int)

    absorb(aad)
    absorb(ciphertext)
    length_block = (len(aad) * 8).to_bytes(8, "big") + (len(ciphertext) * 8).to_bytes(8, "big")
    y = _gcm_mul(y ^ int.from_bytes(length_block, "big"), h_int)
    return y.to_bytes(16, "big")


def _inc32(counter: bytes) -> bytes:
    number = int.from_bytes(counter[12:], "big")
    return counter[:12] + ((number + 1) & 0xFFFFFFFF).to_bytes(4, "big")


def aes128_gcm_encrypt(key: bytes, nonce: bytes, plaintext: bytes, aad: bytes) -> tuple[bytes, bytes]:
    if len(nonce) != 12:
        raise ValueError("GCM nonce must be 12 bytes")
    hash_key = aes128_encrypt_block(key, b"\x00" * 16)
    j0 = nonce + b"\x00\x00\x00\x01"
    counter = _inc32(j0)
    ciphertext = b""
    for offset in range(0, len(plaintext), 16):
        block = plaintext[offset : offset + 16]
        stream = aes128_encrypt_block(key, counter)
        ciphertext += _xor(block, stream[: len(block)])
        counter = _inc32(counter)
    tag = _xor(aes128_encrypt_block(key, j0), _ghash(hash_key, aad, ciphertext))
    return ciphertext, tag


def aes128_gcm_decrypt(key: bytes, nonce: bytes, ciphertext: bytes, aad: bytes, tag: bytes) -> bytes:
    if len(tag) != 16:
        raise ValueError("GCM tag must be 16 bytes")
    hash_key = aes128_encrypt_block(key, b"\x00" * 16)
    j0 = nonce + b"\x00\x00\x00\x01"
    expected = _xor(aes128_encrypt_block(key, j0), _ghash(hash_key, aad, ciphertext))
    if expected != tag:
        raise ValueError("GCM tag mismatch")
    counter = _inc32(j0)
    plaintext = b""
    for offset in range(0, len(ciphertext), 16):
        block = ciphertext[offset : offset + 16]
        stream = aes128_encrypt_block(key, counter)
        plaintext += _xor(block, stream[: len(block)])
        counter = _inc32(counter)
    return plaintext
