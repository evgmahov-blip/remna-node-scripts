"""Root-only WARP secret files. Status views are redacted."""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path

from security.v2.contracts import WARP_STATUS, assert_valid, redact
from security.v2.warp_register import WarpMaterial


def secret_path(base: Path) -> Path:
    return base / "v2" / "egress" / "secrets" / "warp.json"


def lkg_path(base: Path) -> Path:
    return base / "v2" / "egress" / "secrets" / "warp.lkg.json"


def _encode(material: WarpMaterial) -> dict:
    return {
        "private_key": base64.b64encode(material.private_key).decode("ascii"),
        "public_key": base64.b64encode(material.public_key).decode("ascii"),
        "token": material.token,
        "provider_account_id": material.provider_account_id,
        "peer_public_key": material.peer_public_key,
        "addresses_v4": material.addresses_v4,
        "addresses_v6": material.addresses_v6,
        "endpoint_host": material.endpoint_host,
        "endpoint_v4": material.endpoint_v4,
        "endpoint_v6": material.endpoint_v6,
        "reserved": material.reserved,
        "verified_expiry": material.verified_expiry,
        "created_at": material.created_at,
        "last_success_at": material.last_success_at,
        "rotation_generation": material.rotation_generation,
        "orphan_risk": material.orphan_risk,
        "deletion_claimed": material.deletion_claimed,
    }


def _write(path: Path, material: WarpMaterial) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(_encode(material), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def stage_generation(base: Path, material: WarpMaterial) -> Path:
    path = base / "v2" / "egress" / "secrets" / f"warp.gen{material.rotation_generation}.json"
    _write(path, material)
    return path


def promote_lkg(base: Path, material: WarpMaterial, selftest) -> dict:
    """Replace last-known-good only after selftest passes."""
    staged = stage_generation(base, material)
    result = selftest(staged)
    if not result.get("ok"):
        return {"ok": False, "promoted": False, "reason": result.get("reason", "selftest_failed"), "lkg": lkg_path(base).exists()}
    _write(secret_path(base), material)
    _write(lkg_path(base), material)
    return {"ok": True, "promoted": True, "generation": material.rotation_generation}


def status(base: Path) -> dict:
    path = secret_path(base)
    if not path.exists():
        doc = {
            "schema": WARP_STATUS,
            "registered": False,
            "redacted": True,
            "orphan_risk": False,
            "has_lkg": lkg_path(base).exists(),
            "rotation_generation": None,
            "verified_expiry": None,
            "last_success_at": None,
        }
        return assert_valid(WARP_STATUS, doc)
    raw = json.loads(path.read_text(encoding="utf-8"))
    public = redact(raw)
    doc = {
        "schema": WARP_STATUS,
        "registered": True,
        "redacted": True,
        "orphan_risk": bool(raw.get("orphan_risk")),
        "has_lkg": lkg_path(base).exists(),
        "rotation_generation": raw.get("rotation_generation"),
        "verified_expiry": raw.get("verified_expiry"),
        "last_success_at": raw.get("last_success_at"),
        "endpoint_host": public.get("endpoint_host"),
        "peer_public_key": public.get("peer_public_key"),
    }
    return assert_valid(WARP_STATUS, doc)


def file_mode(path: Path) -> int:
    return os.stat(path).st_mode & 0o777
