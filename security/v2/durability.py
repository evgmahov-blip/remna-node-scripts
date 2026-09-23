"""Crash-oriented writes: temp file, file fsync, atomic rename, parent fsync.

Unsupported fsync is reported as degraded. Callers must not describe a degraded
commit as fully crash-safe. errno values covered: EINVAL, ENOTSUP, EOPNOTSUPP.
"""

from __future__ import annotations

import errno
import os
from pathlib import Path

UNSUPPORTED = {errno.EINVAL, errno.ENOTSUP, getattr(errno, "EOPNOTSUPP", 95)}


class FsyncUnsupported(OSError):
    pass


class PosixFsync:
    name = "posix"

    def fsync_file(self, fd: int) -> str:
        try:
            os.fsync(fd)
        except OSError as exc:
            if exc.errno in UNSUPPORTED:
                return "unsupported"
            raise
        return "full"

    def fsync_dir(self, path: Path) -> str:
        try:
            fd = os.open(str(path), os.O_RDONLY)
        except OSError as exc:
            if exc.errno in UNSUPPORTED:
                return "unsupported"
            raise
        try:
            return self.fsync_file(fd)
        finally:
            os.close(fd)


class DegradedFsync:
    """Test double for filesystems that cannot fsync."""

    name = "degraded"

    def fsync_file(self, fd: int) -> str:
        return "unsupported"

    def fsync_dir(self, path: Path) -> str:
        return "unsupported"


def atomic_write(path: Path, data: bytes, backend, *, mode: int = 0o600) -> dict:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    steps = []
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.write(fd, data)
        file_sync = backend.fsync_file(fd)
        steps.append({"step": "file_fsync", "result": file_sync})
    finally:
        os.close(fd)
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    steps.append({"step": "rename", "result": "full"})
    dir_sync = backend.fsync_dir(path.parent)
    steps.append({"step": "parent_fsync", "result": dir_sync})
    durability = "full"
    if any(step["result"] == "unsupported" for step in steps):
        durability = "degraded"
    return {"path": str(path), "durability": durability, "steps": steps, "mode": oct(mode)}
