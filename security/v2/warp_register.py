"""Local WARP registration client.

The request shape follows the reviewed Cloudflare client registration idea.
There is no Vercel, Upstash, public subscription, or external secret store.

Non-idempotent registration is not retried after an ambiguous timeout.
Idempotent enable/update may use a bounded retry. Expiry is recorded only
when the provider response actually contains it.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field

from security.v2.x25519 import generate_private_key, public_key


class RegistrationError(Exception):
    def __init__(self, kind: str, detail: str, *, retryable: bool = False):
        super().__init__(detail)
        self.kind = kind
        self.detail = detail
        self.retryable = retryable


@dataclass
class WarpMaterial:
    private_key: bytes
    public_key: bytes
    token: str
    provider_account_id: str
    peer_public_key: str
    addresses_v4: str
    addresses_v6: str
    endpoint_host: str
    endpoint_v4: str | None
    endpoint_v6: str | None
    reserved: str | None
    verified_expiry: str | None
    created_at: int
    last_success_at: int | None = None
    rotation_generation: int = 1
    orphan_risk: bool = False
    deletion_claimed: bool = False
    notes: list[str] = field(default_factory=list)


def build_registration_body(private_key: bytes, now_iso: str) -> dict:
    pub = public_key(private_key)
    return {
        "key": _b64(pub),
        "install_id": "",
        "fcm_token": "",
        "tos": now_iso,
        "type": "Android",
        "model": "PC",
        "locale": "en_US",
    }


def _b64(data: bytes) -> str:
    import base64

    return base64.b64encode(data).decode("ascii")


def parse_registration_response(status: int, body: bytes, content_type: str = "") -> dict:
    if status == 0:
        raise RegistrationError("network", "no response", retryable=False)
    lowered = body[:512].lower()
    if body[:1] in (b"<",) or b"<html" in lowered or b"cloudflare" in lowered and b"attention required" in lowered:
        raise RegistrationError("waf", "html or interstitial", retryable=False)
    if status < 200 or status >= 300:
        raise RegistrationError("http_error", f"http {status}", retryable=500 <= status <= 599)
    try:
        doc = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RegistrationError("non_json", "body is not json", retryable=False) from exc
    if not isinstance(doc, dict):
        raise RegistrationError("non_json", "json is not an object", retryable=False)
    config = doc.get("config") or {}
    peers = config.get("peers") or []
    if not peers or not isinstance(peers, list):
        raise RegistrationError("non_json", "missing peers", retryable=False)
    peer = peers[0]
    endpoint = peer.get("endpoint") or {}
    interface = (config.get("interface") or {}).get("addresses") or {}
    expiry = None
    for key in ("expiry", "expires", "expires_at"):
        if key in doc and isinstance(doc[key], str):
            expiry = doc[key]
            break
    return {
        "provider_account_id": str(doc.get("id") or ""),
        "token": str(doc.get("token") or ""),
        "peer_public_key": str(peer.get("public_key") or ""),
        "endpoint_host": str(endpoint.get("host") or ""),
        "endpoint_v4": endpoint.get("v4"),
        "endpoint_v6": endpoint.get("v6"),
        "addresses_v4": str(interface.get("v4") or ""),
        "addresses_v6": str(interface.get("v6") or ""),
        "reserved": config.get("client_id"),
        "verified_expiry": expiry,
    }


def registration_may_retry(error: RegistrationError, attempt: int, *, limit: int = 2) -> bool:
    """attempt is the number of failures so far, starting at 1."""
    if error.kind == "ambiguous_timeout":
        return False
    if error.kind == "network" and attempt < limit:
        return True
    return False


def idempotent_may_retry(error: RegistrationError, attempt: int, *, limit: int = 3) -> bool:
    if attempt >= limit:
        return False
    if error.kind in {"network", "ambiguous_timeout", "http_error"} and (error.retryable or error.kind == "ambiguous_timeout"):
        return True
    return False


def register_once(transport, private_key: bytes, now_iso: str) -> dict:
    """transport(request_dict) -> (status:int, body:bytes) or raises RegistrationError."""
    request = {
        "method": "POST",
        "url": "https://api.cloudflareclient.com/v0a2158/reg",
        "headers": {"Content-Type": "application/json"},
        "body": build_registration_body(private_key, now_iso),
        "idempotent": False,
    }
    try:
        status, body = transport(request)
    except RegistrationError:
        raise
    except TimeoutError as exc:
        raise RegistrationError("ambiguous_timeout", "timeout after the request may have been sent", retryable=False) from exc
    except OSError as exc:
        raise RegistrationError("network", str(exc), retryable=True) from exc
    return parse_registration_response(status, body)


def register_with_policy(transport, private_key: bytes, now_iso: str) -> dict:
    attempt = 0
    while True:
        attempt += 1
        try:
            return register_once(transport, private_key, now_iso)
        except RegistrationError as exc:
            if not registration_may_retry(exc, attempt):
                raise


def new_identity(rng: bytes | None = None) -> tuple[bytes, bytes]:
    private = generate_private_key(rng)
    return private, public_key(private)


def ambiguous_cleanup(material: WarpMaterial, deleter) -> WarpMaterial:
    """Never claim deletion when the outcome is ambiguous."""
    try:
        deleter()
    except RegistrationError as exc:
        if exc.kind == "ambiguous_timeout":
            material.orphan_risk = True
            material.deletion_claimed = False
            material.notes.append("orphan_risk")
            return material
        material.deletion_claimed = False
        material.notes.append(exc.kind)
        return material
    material.deletion_claimed = True
    material.orphan_risk = False
    return material
