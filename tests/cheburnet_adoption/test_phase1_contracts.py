"""Offline Phase 1 contract tests.

No network, Docker, systemd, firewall, package, Xray, Remnawave or panel access.
"""

from __future__ import annotations

import ast
import json
import unittest
from pathlib import Path

from next_lifecycle import RUNTIME_CAPABILITIES
from next_lifecycle.contracts import (
    IMAGE_PROVENANCE_V1,
    KNOWN_SCHEMA_VERSIONS,
    LIFECYCLE_JOURNAL_V1,
    MUTATION_ENVELOPE_V1,
    RELEASE_BINDING_V1,
    SECRET_PREFLIGHT_V1,
    SECURITY_V2_LOCK_ORDER,
    VERIFY_RESULT_V1,
    aggregate_verify,
    load_schema,
    parse_journal_payload,
    policy_binding_result,
    seal_journal_record,
    validate_image_provenance,
    validate_journal,
    validate_mutation_envelope,
    validate_release_binding,
    validate_secret_preflight,
    validate_verify_result,
)

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "next_lifecycle"
FP = "ab" * 32
FP2 = "cd" * 32
COMMIT = "12" * 20
DIGEST = "sha256:" + FP
DIGEST2 = "sha256:" + FP2


def _provenance():
    return {"candidate_commit": COMMIT, "release_id": None}


def _lock_holder():
    return {
        "boot_id": "boot-1",
        "process_identity": "pid-10",
        "acquisition_generation": 3,
        "fencing_token": "fence-3",
    }


def _evidence(name: str):
    return {"evidence_id": name, "content_sha256": FP}


def _gen(name: str, fingerprint: str = FP):
    return {"generation": name, "fingerprint": fingerprint}


def _record(sequence: int = 1, **overrides):
    record = {
        "schema_version": LIFECYCLE_JOURNAL_V1,
        "transaction_id": "tx-1",
        "operation_id": f"op-{sequence}",
        "step": "precheck",
        "idempotence_class": "IDEMPOTENT_RETRY",
        "expected_before": _gen("gen-0"),
        "expected_after": _gen("gen-1", FP2),
        "manager_prepare_evidence": _evidence("prepare"),
        "manager_commit_evidence": _evidence("commit"),
        "effective_runtime_state": _gen("gen-1", FP2),
        "rollback": {"reference": "gen-0", "outcome": "NOT_ATTEMPTED"},
        "sequence": sequence,
        "provenance": _provenance(),
        "lock_holder": _lock_holder(),
        "recovery": {"class": "NONE"},
    }
    record.update(overrides)
    return seal_journal_record(record)


def _journal(records=None):
    if records is None:
        records = [
            _record(1),
            _record(2, step="apply", idempotence_class="RECONCILE_THEN_RETRY"),
        ]
    return {
        "schema_version": LIFECYCLE_JOURNAL_V1,
        "transaction_id": "tx-1",
        "provenance": _provenance(),
        "records": records,
    }


def _mixed_recovery():
    return {
        "class": "MIXED_GENERATION_MANUAL_RECOVERY",
        "transaction_id": "tx-1",
        "participants": [
            {
                "manager": "next-transport",
                "object_id": "profile",
                "observed_generation": "gen-1",
                "observed_fingerprint": FP2,
                "rollback_outcome": "ROLLED_BACK",
            },
            {
                "manager": "systemd-dropin",
                "object_id": "unit",
                "observed_generation": "gen-1",
                "observed_fingerprint": FP,
                "rollback_outcome": "ROLLBACK_FAILED",
            },
        ],
        "forward_progress_permitted": False,
        "new_mutation_permitted": False,
        "release_permitted": False,
        "activation_permitted": False,
    }


def _envelope():
    return {
        "schema_version": MUTATION_ENVELOPE_V1,
        "manager_name": "next-transport",
        "manager_schema_version": "next-transport.v1",
        "transaction_id": "tx-1",
        "operation_id": "op-1",
        "owned_objects": [
            {"owner": "security-v2", "layer": "inbound", "object_id": "guard"},
            {"owner": "security-v2", "layer": "transport", "object_id": "profile"},
        ],
        "expected_current": _gen("gen-0"),
        "proposed_next": _gen("gen-1", FP2),
        "fencing_token": "fence-3",
        "prepare_evidence": _evidence("prepare"),
        "commit_evidence": _evidence("commit"),
        "postcheck_evidence": _evidence("postcheck"),
        "rollback_evidence": _evidence("rollback"),
        "mutation_gate": {
            "context": "lifecycle-transaction",
            "gate_id": "gate-1",
            "execution": "contract-only",
        },
        "security_v2_lock_order": list(SECURITY_V2_LOCK_ORDER),
        "pure": True,
    }


def _check(check_id: str, status: str = "PASS", **overrides):
    item = {
        "check_id": check_id,
        "required": True,
        "configured": True,
        "observed_at": 1_700_000_000,
        "freshness_ttl_seconds": 60,
        "timeout_seconds": 5,
        "evidence_source": "fixture",
        "status": status,
        "reason_code": "ok" if status == "PASS" else status.lower(),
    }
    item.update(overrides)
    return item


def _verify(checks=None, policy_hash: str = FP):
    return {
        "schema_version": VERIFY_RESULT_V1,
        "policy_version": "verify-policy.v1",
        "policy_hash": policy_hash,
        "checks": checks if checks is not None else [_check("runtime"), _check("image")],
    }


def _policy(policy_hash: str = FP, required=None):
    return {
        "policy_version": "verify-policy.v1",
        "policy_hash": policy_hash,
        "required_check_ids": ["runtime", "image"] if required is None else required,
    }


def _image():
    return {
        "schema_version": IMAGE_PROVENANCE_V1,
        "registry": "registry.example",
        "repository": "remnanode/next",
        "platform": {"os": "linux", "architecture": "amd64"},
        "manifest_digest": DIGEST,
        "platform_digest": DIGEST2,
        "running_image_id": DIGEST2,
        "running_repo_digest": DIGEST2,
        "trust_policy_version": "trust-policy.v1",
        "trust_policy_hash": FP,
        "trust_basis": "platform_digest",
        "signer": {"id": "signer-1"},
        "issuer": {"id": "issuer-1"},
        "attestation": {"id": "att-1", "type": "dsse"},
        "lkg": {
            "image_id": DIGEST,
            "platform_digest": DIGEST,
            "retention_protected": True,
        },
    }


def _secret(ok: bool = False):
    return {
        "schema_version": SECRET_PREFLIGHT_V1,
        "secret_present": True,
        "structure_valid": ok,
        "certificate_chain_valid": ok,
        "certificate_time_valid": ok,
        "private_key_matches": ok,
        "jwt_key_valid": ok,
        "failure_status": "OK" if ok else "PRECHECK_FAILED",
        "failure_reason": "" if ok else "STRUCTURE_INVALID",
        "fingerprints": {"structure": FP} if ok else {},
    }


def _release():
    return {
        "schema_version": RELEASE_BINDING_V1,
        "reviewed_candidate_commit": COMMIT,
        "source_blob_hashes": {"install.sh": FP},
        "artifact_hashes": {"next-bundle": FP2},
        "runtime_image_platform_digest": DIGEST2,
        "verify_policy_hash": FP,
        "trust_policy_hash": FP2,
        "review_evidence_ids": ["review-1"],
        "release_approval_id": "approval-1",
        "activation_authorized": False,
    }


class Phase1Contracts(unittest.TestCase):
    def test_valid_schemas_and_contracts(self):
        for version in KNOWN_SCHEMA_VERSIONS:
            schema = load_schema(version)
            self.assertEqual(schema["title"], version)
            self.assertTrue(schema["required"])
        self.assertEqual(validate_journal(_journal()), [])
        self.assertEqual(validate_mutation_envelope(_envelope()), [])
        self.assertEqual(validate_verify_result(_verify()), [])
        aggregate = aggregate_verify(_verify(), _policy())
        self.assertEqual(aggregate["status"], "PASS")
        self.assertEqual(aggregate["exit_code"], 0)
        self.assertEqual(validate_image_provenance(_image(), expected_trust_policy_hash=FP), [])
        self.assertEqual(validate_secret_preflight(_secret(False)), [])
        self.assertEqual(validate_secret_preflight(_secret(True)), [])
        self.assertEqual(validate_release_binding(_release()), [])

    def test_manual_and_mixed_recovery_contracts(self):
        manual = _record(
            recovery={
                "class": "MANUAL_RECOVERY_REQUIRED",
                "reason_code": "STALE_LOCK",
                "forward_progress_permitted": False,
                "new_mutation_permitted": False,
                "release_permitted": False,
                "activation_permitted": False,
            }
        )
        mixed = _record(2, operation_id="op-mixed", recovery=_mixed_recovery())
        self.assertEqual(validate_journal(_journal([manual, mixed])), [])

    def test_missing_or_unknown_schema_version_fails_closed(self):
        journal = _journal()
        journal.pop("schema_version")
        self.assertIn("fail-closed: missing schema_version", validate_journal(journal))
        journal = _journal()
        journal["schema_version"] = "remnanode-next.lifecycle-journal.v2"
        self.assertIn("fail-closed: unknown schema_version", validate_journal(journal))
        envelope = _envelope()
        envelope["schema_version"] = "remnanode-next.mutation-envelope.v9"
        self.assertIn("fail-closed: unknown schema_version", validate_mutation_envelope(envelope))

    def test_corrupt_checksum_and_torn_record_rejected(self):
        raw = json.dumps(_journal())
        document, errors = parse_journal_payload(raw[:-8])
        self.assertIsNone(document)
        self.assertIn("fail-closed: torn or truncated record", errors)
        broken = _journal()
        broken["records"][0]["integrity_sha256"] = "0" * 64
        self.assertIn("fail-closed: integrity mismatch", validate_journal(broken))

    def test_out_of_order_and_duplicate_sequence_rejected(self):
        duplicate = _journal([_record(1), _record(1, operation_id="op-other")])
        self.assertIn("fail-closed: duplicate sequence", validate_journal(duplicate))
        gap = _journal([_record(1), _record(3, operation_id="op-3")])
        self.assertIn("fail-closed: out-of-order sequence", validate_journal(gap))

    def test_invalid_idempotence_class_rejected(self):
        record = _record(idempotence_class="RETRY")
        self.assertIn("invalid idempotence_class", validate_journal(_journal([record])))
        journal = _journal()
        journal["provenance"] = {"candidate_commit": "34" * 20, "release_id": None}
        self.assertIn("provenance mismatch", validate_journal(journal))

    def test_missing_fencing_token_and_wrong_lock_order_rejected(self):
        envelope = _envelope()
        del envelope["fencing_token"]
        self.assertIn("missing fencing_token", validate_mutation_envelope(envelope))
        envelope = _envelope()
        envelope["security_v2_lock_order"] = ["egress", "transport", "inbound", "transaction"]
        self.assertIn("security_v2_lock_order", validate_mutation_envelope(envelope))
        envelope = _envelope()
        envelope["mutation_gate"]["execution"] = "apply"
        self.assertIn("mutation_gate.execution", validate_mutation_envelope(envelope))
        envelope = _envelope()
        envelope["owned_objects"][0]["layer"] = "firewall-shadow"
        self.assertIn("owned_objects.layer", validate_mutation_envelope(envelope))

    def test_required_unknown_is_non_success(self):
        result = aggregate_verify(
            _verify([_check("runtime", "UNKNOWN"), _check("image")]), _policy()
        )
        self.assertEqual(result["status"], "UNKNOWN")
        self.assertNotEqual(result["exit_code"], 0)
        self.assertFalse(result["success"])

    def test_required_fail_is_non_success(self):
        result = aggregate_verify(
            _verify([_check("runtime", "FAIL"), _check("image")]), _policy()
        )
        self.assertEqual(result["status"], "FAIL")
        self.assertNotEqual(result["exit_code"], 0)

    def test_missing_required_check_is_unknown(self):
        result = aggregate_verify(_verify([_check("runtime")]), _policy())
        self.assertEqual(result["status"], "UNKNOWN")
        self.assertIn("missing required check", result["errors"])

    def test_malformed_check_is_unknown(self):
        bad = _check("runtime")
        bad["status"] = "OK"
        result = aggregate_verify(_verify([bad, _check("image")]), _policy())
        self.assertEqual(result["status"], "UNKNOWN")
        self.assertIn("malformed check", result["errors"])

    def test_not_configured_only_when_optional(self):
        optional = _check(
            "telemt",
            "NOT_CONFIGURED",
            required=False,
            configured=False,
            reason_code="absent",
        )
        ok = aggregate_verify(
            _verify([_check("runtime"), _check("image"), optional]), _policy()
        )
        self.assertEqual(ok["status"], "PASS")
        required = _check("runtime", "NOT_CONFIGURED", configured=False)
        blocked = aggregate_verify(_verify([required, _check("image")]), _policy())
        self.assertEqual(blocked["status"], "UNKNOWN")
        self.assertIn("NOT_CONFIGURED not allowed", blocked["errors"])

    def test_secret_looking_raw_fields_rejected(self):
        leaked = _secret(False)
        leaked["private_key"] = "-----BEGIN PRIVATE KEY-----\nABC\n"
        self.assertIn("secret-looking field", validate_secret_preflight(leaked))
        token = _secret(False)
        token["access_token"] = "eyJhbGciOiJub25l.eyJzdWIiOiJub2Rl.sig"
        self.assertIn("secret-looking field", validate_secret_preflight(token))
        self.assertNotIn('"private_key"', json.dumps(_secret(True)))

    def test_mutable_tag_only_and_missing_platform_digest_rejected(self):
        tagged = _image()
        tagged["trust_basis"] = "mutable_tag"
        tagged["reference_tag"] = "latest"
        self.assertIn("mutable-tag-only trust", validate_image_provenance(tagged))
        missing = _image()
        del missing["platform_digest"]
        self.assertIn("missing platform_digest", validate_image_provenance(missing))

    def test_lkg_requires_exact_image_id_and_digest(self):
        tag_only = _image()
        tag_only["lkg"] = {"image_id": "latest", "retention_protected": True}
        errors = validate_image_provenance(tag_only)
        self.assertIn("lkg missing image_id", errors)
        self.assertIn("lkg missing platform_digest", errors)
        unprotected = _image()
        unprotected["lkg"]["retention_protected"] = False
        self.assertIn("lkg.retention_protected", validate_image_provenance(unprotected))

    def test_release_evidence_cannot_authorize_activation(self):
        self.assertEqual(validate_release_binding(_release()), [])
        authorized = _release()
        authorized["activation_authorized"] = True
        self.assertIn("activation_authorized", validate_release_binding(authorized))
        implied = _release()
        implied["activation_target"] = "node-1"
        self.assertIn("activation_authorized", validate_release_binding(implied))

    def test_policy_hash_mismatch_fails_closed(self):
        mismatch = aggregate_verify(_verify(), _policy(policy_hash=FP2))
        self.assertEqual(mismatch["status"], "UNKNOWN")
        self.assertIn("fail-closed: verify_policy_hash_mismatch", mismatch["errors"])
        image_errors = validate_image_provenance(
            _image(), expected_trust_policy_hash=FP2
        )
        self.assertIn("fail-closed: trust_policy_hash_mismatch", image_errors)
        wrong_runtime = _image()
        wrong_runtime["running_repo_digest"] = DIGEST
        self.assertIn(
            "running_repo_digest does not match approved platform_digest",
            validate_image_provenance(wrong_runtime),
        )
        wrong_version_policy = _policy()
        wrong_version_policy["policy_version"] = "verify-policy.v2"
        version_result = aggregate_verify(_verify(), wrong_version_policy)
        self.assertEqual(version_result["status"], "UNKNOWN")
        self.assertIn(
            "fail-closed: verify_policy_version_mismatch", version_result["errors"]
        )
        binding = policy_binding_result(
            _release(),
            observed_verify_policy_hash="ff" * 32,
            observed_trust_policy_hash=FP2,
        )
        self.assertFalse(binding["accepted"])
        self.assertTrue(binding["fail_closed"])

    def test_package_has_no_runtime_side_effect_capabilities(self):
        self.assertEqual(RUNTIME_CAPABILITIES, frozenset())
        banned_modules = {
            "subprocess",
            "socket",
            "urllib",
            "http",
            "ftplib",
            "ctypes",
            "pty",
            "docker",
        }
        banned_calls = (
            "systemctl",
            "iptables",
            "nft ",
            "ufw ",
            "docker ",
            "os.system",
            "Popen",
        )
        for path in PACKAGE.rglob("*.py"):
            source = path.read_text(encoding="utf-8")
            tree = ast.parse(source)
            imports = set()
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    imports.update(alias.name.split(".")[0] for alias in node.names)
                elif isinstance(node, ast.ImportFrom) and node.module:
                    imports.add(node.module.split(".")[0])
            self.assertFalse(
                imports & banned_modules,
                f"{path} imports runtime-capable modules: {imports & banned_modules}",
            )
            for marker in banned_calls:
                self.assertNotIn(marker, source, f"{path} contains {marker!r}")


if __name__ == "__main__":
    unittest.main()
