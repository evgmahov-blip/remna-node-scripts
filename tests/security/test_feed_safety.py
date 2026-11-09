"""Offline regression checks for rejected and interrupted feed updates."""
import tempfile
import unittest
from unittest import mock
import os
from pathlib import Path

from security import remna_sec as sec


class FeedSafetyTests(unittest.TestCase):
    def test_manual_list_interrupted_write_preserves_previous_file(self):
        for filename in ("allow.txt", "deny.txt"):
            for remove in (False, True):
                with self.subTest(filename=filename, remove=remove), tempfile.TemporaryDirectory() as td:
                    base = Path(td)
                    path = base / "data" / filename
                    path.parent.mkdir()
                    original = "192.0.2.1/32\n198.51.100.1/32\n"
                    path.write_text(original)
                    path.chmod(0o600)
                    factory = sec.tempfile.NamedTemporaryFile

                    class InterruptedWriter:
                        def __enter__(self):
                            self.stream = factory(mode="w", encoding="utf-8", dir=path.parent,
                                                  prefix=f".{filename}.", delete=False)
                            self.name = self.stream.name
                            return self

                        def write(self, text):
                            self.stream.write(text[:2])
                            self.stream.flush()
                            raise OSError("injected manual-list partial write")

                        def __exit__(self, *args):
                            self.stream.close()

                    value = "192.0.2.1" if remove else "203.0.113.1"
                    with mock.patch.object(sec.tempfile, "NamedTemporaryFile", return_value=InterruptedWriter()):
                        with self.assertRaisesRegex(OSError, "manual-list partial write"):
                            sec.update_list_file(base, filename, value, remove)
                    self.assertEqual(path.read_text(), original)
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(list(path.parent.iterdir()), [path])

                    sec.update_list_file(base, filename, value, remove)
                    expected = (["198.51.100.1/32"] if remove else
                                ["192.0.2.1/32", "198.51.100.1/32", "203.0.113.1/32"])
                    self.assertEqual(path.read_text(), "".join(f"{item}\n" for item in expected))
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_oversized_and_invalid_utf8_are_rejected(self):
        for raw, reason in ((b"#" * 16777217, "oversized"),
                            (b"192.0.2.0/24\n#\xff", "malformed")):
            with self.subTest(reason=reason):
                report = sec.validate_feed(raw, "plain", "ipv4", [], "", [], 1)
                self.assertFalse(report["ok"])
                self.assertEqual(report["reason"], reason)

    def test_promotion_failure_preserves_complete_files(self):
        for failure in ("fsync", "replace", "lkg_replace"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as td:
                base = Path(td)
                live = base / "data" / "antiscanner.txt"
                lkg = base / "data" / "lkg" / live.name
                staged = base / "staging" / live.name
                for path in (live, lkg, staged):
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("old\n" if path != staged else "new\n")
                replace = os.replace

                def fail_replace(src, dst):
                    if failure == "replace" or (failure == "lkg_replace" and dst == lkg):
                        raise OSError("injected rename failure")
                    return replace(src, dst)

                patch = (mock.patch.object(sec.os, "fsync", side_effect=OSError("disk full"))
                         if failure == "fsync" else
                         mock.patch.object(sec.os, "replace", side_effect=fail_replace))
                with patch, self.assertRaises(OSError):
                    sec.promote_staging(base)
                self.assertEqual(live.read_text(), "new\n" if failure == "lkg_replace" else "old\n")
                self.assertEqual(lkg.read_text(), "old\n")
                self.assertEqual(staged.read_text(), "new\n")
                self.assertFalse(list(live.parent.glob(".*")))
                self.assertFalse(list(lkg.parent.glob(".*")))

    def test_partial_write_preserves_previous_file(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "state.json"
            path.write_text("old\n")
            factory = sec.tempfile.NamedTemporaryFile

            class InterruptedWriter:
                def __enter__(self):
                    self.stream = factory(mode="w", encoding="utf-8", dir=path.parent,
                                          prefix=".state.json.", delete=False)
                    self.name = self.stream.name
                    return self

                def write(self, text):
                    self.stream.write(text[:2])
                    self.stream.flush()
                    raise OSError("injected partial write")

                def __exit__(self, *args):
                    self.stream.close()

            with mock.patch.object(sec.tempfile, "NamedTemporaryFile", return_value=InterruptedWriter()):
                with self.assertRaises(OSError):
                    sec.atomic_write_text(path, "new content\n")
            self.assertEqual(path.read_text(), "old\n")
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_directory_fsync_failure_keeps_complete_new_file(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "stats.json"
            path.write_text("old\n")
            with mock.patch.object(sec.os, "fsync", side_effect=[None, OSError("directory sync")]):
                with self.assertRaises(OSError):
                    sec.atomic_write_text(path, "complete new content\n")
            self.assertEqual(path.read_text(), "complete new content\n")
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_atomic_write_and_promotion_success(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            staged = base / "staging" / "antiscanner.txt"
            staged.parent.mkdir()
            staged.write_text("192.0.2.0/24\n")
            sec.promote_staging(base)
            for path in (base / "data" / staged.name, base / "data" / "lkg" / staged.name):
                self.assertEqual(path.read_text(), "192.0.2.0/24\n")
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertFalse(list(staged.parent.iterdir()))

    def test_failed_candidate_cannot_promote_stale_staging(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            (base / "data" / "lkg").mkdir(parents=True)
            (base / "staging").mkdir()
            good = "192.0.2.0/24\n"
            for path in (base / "data" / "antiscanner.txt",
                         base / "data" / "lkg" / "antiscanner.txt"):
                path.write_text(good)
            (base / "staging" / "antiscanner.txt").write_text("198.51.100.0/24\n")
            raw = base / "raw"
            raw.write_text("0.0.0.0/0\n")
            report = sec.accept_source(base, "antiscanner", raw)
            self.assertFalse(report["ok"])
            sec.promote_staging(base)
            self.assertEqual((base / "data" / "antiscanner.txt").read_text(), good)
            self.assertEqual((base / "data" / "lkg" / "antiscanner.txt").read_text(), good)


if __name__ == "__main__":
    unittest.main()
