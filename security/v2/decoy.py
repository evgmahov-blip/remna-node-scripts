"""Stable per-node decoy seed and a rotate/rollback interface.

Runtime trackers and external assets stay off. A full HTML renderer is a
later step; this module keeps the contract and the seed stable.
"""

from __future__ import annotations

import hashlib
import hmac
import json
from pathlib import Path

from security.v2.contracts import DECOY_STATUS, assert_valid

NEXT_STEP = (
    "Render the self-steal template from the stable seed in a later change. "
    "Keep external trackers and remote assets off, and do not let the decoy "
    "path write inbound firewall rules."
)


def node_seed(node_id: str, key: bytes) -> str:
    return hmac.new(key, node_id.encode("utf-8"), hashlib.sha256).hexdigest()


def _path(base: Path) -> Path:
    return base / "v2" / "transport" / "decoy.json"


def _load(base: Path, node_id: str, key: bytes) -> dict:
    path = _path(base)
    fresh = {
        "node_id": node_id,
        "seed": node_seed(node_id, key),
        "generation": 1,
        "history": [1],
        "runtime_trackers": False,
        "external_assets": False,
    }
    if not path.exists():
        return fresh
    state = json.loads(path.read_text(encoding="utf-8"))
    if state.get("node_id") != node_id:
        return fresh
    state["seed"] = node_seed(node_id, key)
    return state


def _save(base: Path, state: dict) -> None:
    path = _path(base)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def status(base: Path, node_id: str, key: bytes) -> dict:
    state = _load(base, node_id, key)
    _save(base, state)
    doc = {
        "schema": DECOY_STATUS,
        "seed": state["seed"],
        "generation": state["generation"],
        "runtime_trackers": False,
        "external_assets": False,
        "next_step": NEXT_STEP,
    }
    return assert_valid(DECOY_STATUS, doc)


def rotate(base: Path, node_id: str, key: bytes) -> dict:
    state = _load(base, node_id, key)
    state["generation"] = int(state["generation"]) + 1
    state["history"].append(state["generation"])
    state["seed"] = node_seed(node_id, key)
    state["runtime_trackers"] = False
    state["external_assets"] = False
    _save(base, state)
    return status(base, node_id, key)


def rollback(base: Path, node_id: str, key: bytes) -> dict:
    state = _load(base, node_id, key)
    history = list(state.get("history") or [state["generation"]])
    if len(history) >= 2:
        history.pop()
        state["generation"] = history[-1]
        state["history"] = history
    state["seed"] = node_seed(node_id, key)
    _save(base, state)
    return status(base, node_id, key)
