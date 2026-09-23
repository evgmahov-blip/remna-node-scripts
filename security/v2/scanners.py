"""Reviewed scanner catalog. Fast feeds stay off unless a later review enables them.

Default-trusted feeds are the existing pinned TSPU and GOV classes. They still
pass the current validation, last-known-good, and panel/allow subtraction
pipeline. A mutable feed cannot be default-trusted without an immutable
checksum, and this candidate does not enable it.
"""

from __future__ import annotations

import hashlib
import importlib.util
from pathlib import Path

from security.v2.contracts import SCANNER_CATALOG, assert_valid

_SEC = Path(__file__).resolve().parent.parent / "remna_sec.py"
_spec = importlib.util.spec_from_file_location("remna_sec", _SEC)
_remna = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_remna)

CATEGORIES = [
    {"id": "tspu", "klass": "slow_reviewed", "default_enabled": True, "mutable": False, "trust": "immutable_pin"},
    {"id": "gov", "klass": "slow_reviewed", "default_enabled": True, "mutable": False, "trust": "immutable_pin"},
    {"id": "censys", "klass": "fast_scanner", "default_enabled": False, "mutable": True, "trust": "untrusted"},
    {"id": "shodan", "klass": "fast_scanner", "default_enabled": False, "mutable": True, "trust": "untrusted"},
    {"id": "shadowserver", "klass": "fast_scanner", "default_enabled": False, "mutable": True, "trust": "untrusted"},
    {"id": "rapid7", "klass": "fast_scanner", "default_enabled": False, "mutable": True, "trust": "untrusted"},
    {"id": "zoomeye", "klass": "fast_scanner", "default_enabled": False, "mutable": True, "trust": "untrusted"},
    {"id": "leakix", "klass": "fast_scanner", "default_enabled": False, "mutable": True, "trust": "untrusted"},
    {"id": "onyphe", "klass": "fast_scanner", "default_enabled": False, "mutable": True, "trust": "untrusted"},
    {"id": "fofa", "klass": "fast_scanner", "default_enabled": False, "mutable": True, "trust": "untrusted"},
    {"id": "quake", "klass": "fast_scanner", "default_enabled": False, "mutable": True, "trust": "untrusted"},
]


def catalog_document() -> dict:
    doc = {
        "schema": SCANNER_CATALOG,
        "categories": CATEGORIES,
        "default_enabled": [item["id"] for item in CATEGORIES if item["default_enabled"]],
        "presets": {
            "safe_default": ["tspu", "gov"],
            "reviewed_only": ["tspu", "gov"],
            "fast_catalog_disabled": [item["id"] for item in CATEGORIES if item["klass"] == "fast_scanner"],
        },
    }
    return assert_valid(SCANNER_CATALOG, doc)


def category(name: str) -> dict:
    for item in CATEGORIES:
        if item["id"] == name:
            return item
    raise KeyError(name)


def admit(name: str, body: bytes, *, provenance: dict | None, panel: str, allow: list[str], previous: list[str]) -> dict:
    meta = category(name)
    if meta["mutable"]:
        return {"ok": False, "reason": "fast_feed_disabled", "enabled": False}
    if meta["trust"] == "immutable_pin":
        if not provenance or not provenance.get("immutable") or not provenance.get("checksum"):
            return {"ok": False, "reason": "missing_immutable_provenance"}
        digest = hashlib.sha256(body).hexdigest()
        if digest != provenance["checksum"]:
            return {"ok": False, "reason": "checksum_mismatch"}
    report = _remna.validate_feed(body, "plain" if name != "gov" else "gov", "ipv4", previous, panel, allow, 1)
    public = {k: v for k, v in report.items() if k != "entries"}
    public["id"] = name
    public["pipeline"] = "validate_lkg_panel_allow"
    return public
