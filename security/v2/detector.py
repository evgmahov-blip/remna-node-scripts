"""Detector facts only. This module never applies firewall, transport, or egress changes."""

from __future__ import annotations

import json
from pathlib import Path

from security.v2.contracts import DETECTOR_FACT, assert_valid

DEFAULT_WINDOW_SECONDS = 60
DEFAULT_RETENTION_SECONDS = 24 * 60 * 60
DEFAULT_QUEUE_LIMIT = 256


class DetectorQueue:
    def __init__(self, base: Path, *, window_seconds: int = DEFAULT_WINDOW_SECONDS, retention_seconds: int = DEFAULT_RETENTION_SECONDS, limit: int = DEFAULT_QUEUE_LIMIT):
        self.path = base / "v2" / "detector" / "facts.json"
        self.window_seconds = window_seconds
        self.retention_seconds = retention_seconds
        self.limit = limit
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def _load(self) -> dict:
        if not self.path.exists():
            return {"facts": [], "overflow_count": 0, "events": []}
        return json.loads(self.path.read_text(encoding="utf-8"))

    def _save(self, state: dict) -> None:
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        tmp.replace(self.path)

    def expire(self, now: int) -> dict:
        state = self._load()
        kept = []
        for fact in state["facts"]:
            age = now - int(fact["observed_at"])
            if age > self.retention_seconds:
                continue
            if age > int(fact["ttl_seconds"]):
                continue
            kept.append(fact)
        state["facts"] = kept
        self._save(state)
        return state

    def ingest(self, fact: dict, now: int) -> dict:
        assert_valid(DETECTOR_FACT, fact)
        state = self.expire(now)
        for existing in state["facts"]:
            if existing["dedup_key"] == fact["dedup_key"] and now - int(existing["observed_at"]) <= self.window_seconds:
                existing["occurrence_count"] = int(existing["occurrence_count"]) + 1
                existing["observed_at"] = now
                self._save(state)
                return {"accepted": True, "deduped": True, "overflow": False, "fact": existing}
        if len(state["facts"]) >= self.limit:
            state["overflow_count"] = int(state["overflow_count"]) + 1
            state["events"].append({"kind": "overflow", "at": now, "dropped_dedup_key": fact["dedup_key"]})
            self._save(state)
            return {"accepted": False, "deduped": False, "overflow": True, "fact": None}
        state["facts"].append(dict(fact))
        self._save(state)
        return {"accepted": True, "deduped": False, "overflow": False, "fact": fact}

    def facts(self, now: int) -> list[dict]:
        return self.expire(now)["facts"]
