"""Owned feature flags. Risky switches default off and fail closed.

FEATURE_AUTO_POLICY is hard-off in this candidate. Setting it in the file
does not enable mutation, and preflight does not rewrite the file to hide
an incompatible combination.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from security.v2.contracts import FEATURE_FLAGS, assert_valid

FLAG_KEYS = (
    "FEATURE_EGRESS_WARP",
    "FEATURE_WARP_QUIC_NOISE",
    "FEATURE_AUTO_POLICY",
    "FEATURE_SCANNER_FAST",
    "FEATURE_NFTABLES_CUTOVER",
    "FEATURE_DECOY_RUNTIME",
    "FEATURE_NODE_PLUGIN",
)

DEFAULTS = {key: 0 for key in FLAG_KEYS}


def policy_path(base: Path) -> Path:
    return base / "v2" / "policy" / "features.json"


def write_flags(base: Path, configured: dict) -> dict:
    unknown = set(configured) - set(FLAG_KEYS)
    if unknown:
        raise ValueError("unknown flags: " + ",".join(sorted(unknown)))
    merged = dict(DEFAULTS)
    for key, value in configured.items():
        if value not in (0, 1):
            raise ValueError(f"{key} must be 0 or 1")
        merged[key] = value
    path = policy_path(base)
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    payload = json.dumps({"configured": merged}, indent=2, sort_keys=True) + "\n"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(payload, encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    os.chmod(path, 0o600)
    return evaluate_flags(base)


def load_configured(base: Path) -> dict:
    path = policy_path(base)
    merged = dict(DEFAULTS)
    if not path.exists():
        return merged
    doc = json.loads(path.read_text(encoding="utf-8"))
    for key, value in (doc.get("configured") or {}).items():
        if key in merged and value in (0, 1):
            merged[key] = value
    return merged


def dependency_errors(configured: dict) -> list[str]:
    errors = []
    if configured.get("FEATURE_WARP_QUIC_NOISE") == 1 and configured.get("FEATURE_EGRESS_WARP") != 1:
        errors.append("quic_noise_requires_warp")
    if configured.get("FEATURE_AUTO_POLICY") == 1:
        errors.append("auto_policy_not_enabled_in_this_candidate")
    if configured.get("FEATURE_NFTABLES_CUTOVER") == 1:
        errors.append("nftables_cutover_not_enabled_in_this_candidate")
    if configured.get("FEATURE_SCANNER_FAST") == 1:
        errors.append("scanner_fast_not_enabled_in_this_candidate")
    if configured.get("FEATURE_DECOY_RUNTIME") == 1:
        errors.append("decoy_runtime_not_enabled_in_this_candidate")
    if configured.get("FEATURE_NODE_PLUGIN") == 1:
        errors.append("node_plugin_not_enabled_in_this_candidate")
    return errors


def effective_flags(configured: dict) -> dict:
    """Fail closed. Does not write a corrected config."""
    effective = dict(configured)
    effective["FEATURE_AUTO_POLICY"] = 0
    effective["FEATURE_NFTABLES_CUTOVER"] = 0
    if configured.get("FEATURE_EGRESS_WARP") != 1:
        effective["FEATURE_WARP_QUIC_NOISE"] = 0
        effective["FEATURE_EGRESS_WARP"] = 0
    if "quic_noise_requires_warp" in dependency_errors(configured):
        effective["FEATURE_WARP_QUIC_NOISE"] = 0
    effective["FEATURE_DECOY_RUNTIME"] = 0
    effective["FEATURE_NODE_PLUGIN"] = 0
    effective["FEATURE_SCANNER_FAST"] = 0
    return effective


def evaluate_flags(base: Path) -> dict:
    configured = load_configured(base)
    errors = dependency_errors(configured)
    doc = {
        "schema": FEATURE_FLAGS,
        "configured": configured,
        "effective": effective_flags(configured),
        "validation": {"ok": not errors, "errors": errors},
        "auto_policy_hard_off": True,
        "rewritten": False,
        "live_effect": False,
    }
    return assert_valid(FEATURE_FLAGS, doc)


def assert_auto_policy_blocked(base: Path) -> None:
    """Every mutating policy path calls this first."""
    doc = evaluate_flags(base)
    if doc["effective"]["FEATURE_AUTO_POLICY"] != 0:
        raise RuntimeError("FEATURE_AUTO_POLICY effective state escaped the hard guard")
    if doc["configured"]["FEATURE_AUTO_POLICY"] != 0:
        raise PermissionError("auto_policy_configured_but_hard_off")
    raise PermissionError("auto_policy_off")
