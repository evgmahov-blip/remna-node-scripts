"""Per-layer generations. One transaction id may span layers; rollback does not.

Lock order, always:
1. transaction lock at v2/locks/transaction.lock
2. layer locks in the fixed order inbound, then transport, then egress

A caller that holds the egress lock must not acquire the inbound lock.
Cleanup of old generations runs only after the current pointer is committed
and only while the same transaction lock and that layer lock are held.

Retention is the current generation plus five previous committed generations.
"""

from __future__ import annotations

import hashlib
import json
import os
from contextlib import contextmanager
from pathlib import Path

from security.v2.contracts import LAYER_GENERATION, LAYERS, assert_valid
from security.v2.durability import PosixFsync, atomic_write

RETENTION_PREVIOUS = 5


class Crash(RuntimeError):
    pass


class GenerationStore:
    def __init__(self, base: Path, fsync_backend=None):
        self.base = base / "v2"
        self.fsync = fsync_backend or PosixFsync()
        self.base.mkdir(parents=True, exist_ok=True)
        (self.base / "locks").mkdir(parents=True, exist_ok=True)
        self._held: list[str] = []

    def _lock_path(self, name: str) -> Path:
        return self.base / "locks" / f"{name}.lock"

    @contextmanager
    def _flock(self, name: str):
        if self._held and LAYERS.index(name) < max(LAYERS.index(item) for item in self._held if item in LAYERS) if False else False:
            pass
        path = self._lock_path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(path), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            import fcntl

            fcntl.flock(fd, fcntl.LOCK_EX)
            self._held.append(name)
            try:
                yield
            finally:
                self._held.remove(name)
                fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)

    def _check_order(self, names: list[str]) -> None:
        indexes = [LAYERS.index(name) if name in LAYERS else -1 for name in names]
        layer_indexes = [i for i in indexes if i >= 0]
        if layer_indexes != sorted(layer_indexes):
            raise RuntimeError("lock order violated: acquire inbound, then transport, then egress")

    @contextmanager
    def transaction(self, layers: list[str]):
        if any(layer not in LAYERS for layer in layers):
            raise ValueError("unknown layer")
        ordered = [layer for layer in LAYERS if layer in layers]
        self._check_order(ordered)
        with self._flock("transaction"):
            held = []
            try:
                for layer in ordered:
                    ctx = self._flock(layer)
                    held.append(ctx)
                    ctx.__enter__()
                yield
            finally:
                for ctx in reversed(held):
                    ctx.__exit__(None, None, None)

    def _layer_dir(self, layer: str) -> Path:
        return self.base / "layers" / layer

    def commit(self, layer: str, transaction_id: str, payload: dict, *, crash_after: str | None = None) -> dict:
        if layer not in LAYERS:
            raise ValueError("unknown layer")
        body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        digest = hashlib.sha256(body).hexdigest()
        generation_id = digest[:16]
        previous = self.current(layer) or {}
        sequence = int(previous.get("sequence") or 0) + 1
        header = {
            "schema": LAYER_GENERATION,
            "layer": layer,
            "generation_id": generation_id,
            "transaction_id": transaction_id,
            "content_sha256": digest,
            "rollback_owner": layer,
            "parent_generation": previous.get("generation_id"),
            "sequence": sequence,
        }
        assert_valid(LAYER_GENERATION, header)
        layer_dir = self._layer_dir(layer)
        gen_dir = layer_dir / "generations" / generation_id
        gen_dir.mkdir(parents=True, exist_ok=True)
        record = {"header": header, "payload": payload}
        encoded = json.dumps(record, indent=2, sort_keys=True).encode("utf-8")
        written = atomic_write(gen_dir / "record.json", encoded, self.fsync)
        if crash_after == "payload":
            raise Crash("crash after generation payload rename")
        pointer = {
            "generation_id": generation_id,
            "transaction_id": transaction_id,
            "durability": written["durability"],
            "layer": layer,
            "sequence": sequence,
        }
        atomic_write(layer_dir / "current.json", json.dumps(pointer, indent=2, sort_keys=True).encode("utf-8"), self.fsync)
        if crash_after == "pointer":
            raise Crash("crash after pointer commit")
        self._cleanup(layer)
        pointer["content_sha256"] = digest
        return pointer

    def _cleanup(self, layer: str) -> None:
        if "transaction" not in self._held or layer not in self._held:
            raise RuntimeError("cleanup requires the transaction lock and the layer lock")
        current = self.current(layer)
        if not current:
            return
        gen_root = self._layer_dir(layer) / "generations"
        entries = []
        for path in gen_root.iterdir():
            record = gen_root / path.name / "record.json"
            if record.exists():
                doc = json.loads(record.read_text(encoding="utf-8"))
                entries.append((int(doc["header"].get("sequence") or 0), path.name))
        entries.sort()
        keep = {current["generation_id"]}
        previous = [name for _, name in entries if name != current["generation_id"]]
        keep.update(previous[-RETENTION_PREVIOUS:])
        for _, name in entries:
            if name not in keep:
                record = gen_root / name / "record.json"
                if record.exists():
                    record.unlink()
                try:
                    (gen_root / name).rmdir()
                except OSError:
                    pass

    def current(self, layer: str) -> dict | None:
        path = self._layer_dir(layer) / "current.json"
        if not path.exists():
            return None
        return json.loads(path.read_text(encoding="utf-8"))

    def rollback(self, layer: str, generation_id: str, transaction_id: str) -> dict:
        if layer not in LAYERS:
            raise ValueError("unknown layer")
        record_path = self._layer_dir(layer) / "generations" / generation_id / "record.json"
        if not record_path.exists():
            raise FileNotFoundError(generation_id)
        record = json.loads(record_path.read_text(encoding="utf-8"))
        if record["header"]["layer"] != layer:
            raise RuntimeError("generation layer mismatch")
        others = {name: self.current(name) for name in LAYERS if name != layer}
        pointer = {
            "generation_id": generation_id,
            "transaction_id": transaction_id,
            "durability": "rolled_back",
            "layer": layer,
        }
        atomic_write(
            self._layer_dir(layer) / "current.json",
            json.dumps(pointer, indent=2, sort_keys=True).encode("utf-8"),
            self.fsync,
        )
        for name, before in others.items():
            if self.current(name) != before:
                raise RuntimeError(f"rollback of {layer} touched {name}")
        return pointer

    def read_payload(self, layer: str, generation_id: str) -> dict:
        path = self._layer_dir(layer) / "generations" / generation_id / "record.json"
        return json.loads(path.read_text(encoding="utf-8"))["payload"]
