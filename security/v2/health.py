"""Endpoint health through an injected WARP-path probe. No public Internet.

Promotion requires two successes. Demotion uses consecutive failures plus
cooldown. After a reboot (boot id change) every endpoint is unknown until
validated again. Probe-target failures are not counted as WARP-path failures.
"""

from __future__ import annotations

import hashlib
import json
import random
from pathlib import Path

from security.v2.contracts import ENDPOINT_HEALTH, assert_valid

PROMOTE_SUCCESSES = 2
DEMOTE_FAILURES = 3


def classify_probe(warp_ok: bool, direct_ok: bool) -> str:
    if warp_ok:
        return "ok"
    if not direct_ok:
        return "probe_target"
    return "warp_path"


def probe_plan(catalog: list[str], seed: str, *, count: int = 2, jitter_max: int = 50) -> dict:
    if len(catalog) < 2:
        raise ValueError("probe catalog needs two independent targets when practical")
    digest = hashlib.sha256(seed.encode("utf-8")).digest()
    start = digest[0] % len(catalog)
    chosen = [catalog[(start + i) % len(catalog)] for i in range(count)]
    rng = random.Random(int.from_bytes(digest, "big"))
    return {"targets": chosen, "jitter_ms": rng.randrange(0, jitter_max + 1), "seed": seed}


class HealthBook:
    def __init__(self, base: Path, boot_id: str, *, cooldown_seconds: int = 120):
        self.path = base / "v2" / "egress" / "health.json"
        self.boot_id = boot_id
        self.cooldown_seconds = cooldown_seconds
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            self.state = {"boot_id": self.boot_id, "records": {}}
            return
        self.state = json.loads(self.path.read_text(encoding="utf-8"))
        if self.state.get("boot_id") != self.boot_id:
            for record in self.state.get("records", {}).values():
                record["status"] = "unknown"
                record["success_streak"] = 0
                record["failure_streak"] = 0
                record["cooldown_until"] = None
            self.state["boot_id"] = self.boot_id
            self._save()

    def _save(self) -> None:
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(self.state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        tmp.replace(self.path)

    def observe(self, endpoint: str, origin: str, kind: str, now: int) -> dict:
        record = self.state["records"].get(endpoint) or {
            "schema": ENDPOINT_HEALTH,
            "endpoint": endpoint,
            "origin": origin,
            "status": "unknown",
            "success_streak": 0,
            "failure_streak": 0,
            "cooldown_until": None,
        }
        if record["status"] == "cooldown" and record.get("cooldown_until") and now < record["cooldown_until"]:
            self.state["records"][endpoint] = record
            self._save()
            return assert_valid(ENDPOINT_HEALTH, record)
        if kind == "ok":
            record["success_streak"] = int(record["success_streak"]) + 1
            record["failure_streak"] = 0
            if record["success_streak"] >= PROMOTE_SUCCESSES:
                record["status"] = "healthy"
            else:
                record["status"] = "candidate"
        elif kind == "warp_path":
            record["failure_streak"] = int(record["failure_streak"]) + 1
            record["success_streak"] = 0
            if record["failure_streak"] >= DEMOTE_FAILURES:
                record["status"] = "cooldown"
                record["cooldown_until"] = now + self.cooldown_seconds
            elif record["status"] != "healthy":
                record["status"] = "candidate"
        elif kind == "probe_target":
            record["status"] = record["status"] if record["status"] != "unknown" else "unknown"
        else:
            raise ValueError("probe kind")
        assert_valid(ENDPOINT_HEALTH, record)
        self.state["records"][endpoint] = record
        self._save()
        return record

    def healthy_keys(self, now: int) -> set[str]:
        keys = set()
        for key, record in self.state["records"].items():
            if record["status"] == "cooldown" and record.get("cooldown_until") and now < record["cooldown_until"]:
                continue
            if record["status"] == "healthy":
                keys.add(key)
        return keys
