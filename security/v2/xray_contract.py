"""Xray/rw-core activation contract and offline outbound shape.

Nothing here starts rw-core, sends a signal, or renames a live config.
Unknown reload methods refuse the plan. SIGHUP is never assumed.
"""

from __future__ import annotations

import base64
import json

from security.v2.contracts import XRAY_ACTIVATION_PLAN, XRAY_ACTIVATION_RESULT, assert_valid

STAGES = [
    "candidate_temp_file",
    "syntax_semantic_validation",
    "rw_core_run_test",
    "snapshot",
    "atomic_rename",
    "reload_or_restart",
    "end_to_end_verification",
    "rollback_on_failure",
]

ALLOWED_RELOAD = {"verified_restart", "detected_api"}


def activation_plan(reload_method: str | None) -> dict:
    reason = None
    method = reload_method or "unknown"
    refused = method not in ALLOWED_RELOAD
    if method == "SIGHUP":
        refused = True
        reason = "sighup_refused"
        method = "unknown"
    elif refused:
        reason = "unknown_reload_method"
    doc = {
        "schema": XRAY_ACTIVATION_PLAN,
        "stages": list(STAGES),
        "reload_method": method,
        "execute": False,
        "refused": refused,
        "reason": reason,
        "activated": False,
    }
    return assert_valid(XRAY_ACTIVATION_PLAN, doc)


def activation_result() -> dict:
    return assert_valid(
        XRAY_ACTIVATION_RESULT,
        {
            "schema": XRAY_ACTIVATION_RESULT,
            "activated": False,
            "stage_reached": "not_started",
            "rolled_back": False,
            "reason": "phase_b_offline_only",
        },
    )


def build_warp_outbounds(
    *,
    secret_key_b64: str,
    peer_public: str,
    endpoint: str,
    address_v4: str,
    address_v6: str,
    quic_packet: bytes,
    reserved: list[int] | None = None,
) -> dict:
    """Wireguard outbound dials through a dedicated freedom outbound.

    The freedom outbound carries one valid QUIC Initial plus rand noises.
    This is a generated shape only. It is not installed.
    """
    if not quic_packet or (quic_packet[0] & 0x80) != 0x80:
        raise ValueError("quic packet must be a long-header datagram")
    noise = base64.b64encode(quic_packet).decode("ascii")
    return {
        "outbounds": [
            {
                "protocol": "wireguard",
                "tag": "warp",
                "settings": {
                    "secretKey": secret_key_b64,
                    "address": [address_v4, address_v6],
                    "peers": [{"publicKey": peer_public, "endpoint": endpoint}],
                    "mtu": 1280,
                    "reserved": reserved or [0, 0, 0],
                    "domainStrategy": "ForceIP",
                },
                "streamSettings": {"sockopt": {"dialerProxy": "warp-quic-noise"}},
            },
            {
                "protocol": "freedom",
                "tag": "warp-quic-noise",
                "settings": {
                    "domainStrategy": "AsIs",
                    "noises": [
                        {"type": "rand", "packet": "10-20", "delay": "10-16"},
                        {"type": "base64", "packet": noise, "delay": "10-20"},
                    ],
                },
            },
        ],
        "notes": [
            "offline candidate only",
            "does not claim undetectable or guaranteed bypass",
        ],
    }


def preflight_config(config: dict) -> dict:
    errors = []
    outbounds = config.get("outbounds") or []
    warp = next((item for item in outbounds if item.get("tag") == "warp"), None)
    freedom = next((item for item in outbounds if item.get("tag") == "warp-quic-noise"), None)
    if not warp or warp.get("protocol") != "wireguard":
        errors.append("missing wireguard warp outbound")
    else:
        dialer = ((warp.get("streamSettings") or {}).get("sockopt") or {}).get("dialerProxy")
        if dialer != "warp-quic-noise":
            errors.append("dialerProxy")
    if not freedom or freedom.get("protocol") != "freedom":
        errors.append("missing freedom noise outbound")
    else:
        noises = (freedom.get("settings") or {}).get("noises") or []
        types = [item.get("type") for item in noises]
        if "rand" not in types or "base64" not in types:
            errors.append("noises")
        for item in noises:
            if item.get("type") == "base64":
                try:
                    raw = base64.b64decode(item.get("packet") or "", validate=True)
                except Exception:
                    errors.append("noise packet")
                    raw = b""
                if not raw or (raw[0] & 0x80) != 0x80:
                    errors.append("noise packet is not a quic long header")
    if any(item.get("protocol") == "hysteria" for item in outbounds):
        errors.append("hysteria2 is not an egress backend")
    return {"ok": not errors, "errors": errors, "execute": False}


def dumps_public(config: dict) -> str:
    cloned = json.loads(json.dumps(config))
    for item in cloned.get("outbounds") or []:
        settings = item.get("settings") or {}
        if "secretKey" in settings:
            settings["secretKey"] = "redacted"
    return json.dumps(cloned, indent=2, sort_keys=True)
