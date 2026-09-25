"""Pure/offline contracts for the reviewed CheburNET adoption architecture.

This module intentionally has no network, subprocess, service, container, firewall,
or filesystem mutation capability. Phase 1 validates data contracts only.
"""

from __future__ import annotations

import copy
import hashlib
import json
import re
from pathlib import Path
from typing import Any, Iterable

LIFECYCLE_JOURNAL_V1 = "remnanode-next.lifecycle-journal.v1"
MUTATION_ENVELOPE_V1 = "remnanode-next.mutation-envelope.v1"
VERIFY_RESULT_V1 = "remnanode-next.verify-result.v1"
IMAGE_PROVENANCE_V1 = "remnanode-next.image-provenance.v1"
SECRET_PREFLIGHT_V1 = "remnanode-next.secret-preflight.v1"
RELEASE_BINDING_V1 = "remnanode-next.release-binding.v1"

KNOWN_SCHEMA_VERSIONS = frozenset(
    {
        LIFECYCLE_JOURNAL_V1,
        MUTATION_ENVELOPE_V1,
        VERIFY_RESULT_V1,
        IMAGE_PROVENANCE_V1,
        SECRET_PREFLIGHT_V1,
        RELEASE_BINDING_V1,
    }
)

SECURITY_V2_LOCK_ORDER = ("transaction", "inbound", "transport", "egress")
IDEMPOTENCE_CLASSES = frozenset(
    {"IDEMPOTENT_RETRY", "RECONCILE_THEN_RETRY", "NON_RETRYABLE_MANUAL"}
)
VERIFY_STATUSES = frozenset({"PASS", "WARN", "FAIL", "NOT_CONFIGURED", "UNKNOWN"})
RECOVERY_CLASSES = frozenset(
    {"NONE", "MANUAL_RECOVERY_REQUIRED", "MIXED_GENERATION_MANUAL_RECOVERY"}
)
ROLLBACK_OUTCOMES = frozenset(
    {"NOT_ATTEMPTED", "ROLLED_BACK", "ROLLBACK_REFUSED", "ROLLBACK_FAILED", "NOT_TOUCHED"}
)

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
_SECRET_VALUE_MARKERS = (
    "-----BEGIN PRIVATE KEY-----",
    "-----BEGIN RSA PRIVATE KEY-----",
    "-----BEGIN EC PRIVATE KEY-----",
    "-----BEGIN CERTIFICATE-----",
)
_ALLOWED_SECRET_KEYS = {
    "schema_version",
    "secret_present",
    "structure_valid",
    "certificate_chain_valid",
    "certificate_time_valid",
    "private_key_matches",
    "jwt_key_valid",
    "failure_status",
    "failure_reason",
    "fingerprints",
}
_BANNED_MUTATION_KEYS = {
    "repair",
    "repair_action",
    "execute",
    "execution_authorized",
    "mutation_gate",
    "activation_target",
}

SCHEMA_DIR = Path(__file__).resolve().parent / "schemas"


def _canonical(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def _is_nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _is_sha256(value: Any) -> bool:
    return isinstance(value, str) and bool(_SHA256_RE.fullmatch(value))


def _is_digest(value: Any) -> bool:
    return isinstance(value, str) and bool(_DIGEST_RE.fullmatch(value))


def _append_missing(errors: list[str], obj: dict[str, Any], fields: Iterable[str]) -> None:
    for field in fields:
        if field not in obj:
            errors.append(f"missing {field}")


def _check_schema(obj: Any, expected: str) -> list[str]:
    if not isinstance(obj, dict):
        return ["fail-closed: object required"]
    version = obj.get("schema_version")
    if version is None:
        return ["fail-closed: missing schema_version"]
    if version != expected:
        return ["fail-closed: unknown schema_version"]
    return []


def load_schema(schema_version: str) -> dict[str, Any]:
    if schema_version not in KNOWN_SCHEMA_VERSIONS:
        raise ValueError("unknown schema version")
    path = SCHEMA_DIR / f"{schema_version}.json"
    return json.loads(path.read_text(encoding="utf-8"))


def seal_journal_record(record: dict[str, Any]) -> dict[str, Any]:
    result = copy.deepcopy(record)
    result.pop("integrity_sha256", None)
    result["integrity_sha256"] = hashlib.sha256(_canonical(result)).hexdigest()
    return result


def _validate_generation(value: Any, label: str, errors: list[str]) -> None:
    if not isinstance(value, dict):
        errors.append(f"{label} object required")
        return
    if not _is_nonempty_string(value.get("generation")):
        errors.append(f"{label}.generation")
    if not _is_sha256(value.get("fingerprint")):
        errors.append(f"{label}.fingerprint")


def _validate_evidence(value: Any, label: str, errors: list[str]) -> None:
    if not isinstance(value, dict):
        errors.append(f"{label} object required")
        return
    if not _is_nonempty_string(value.get("evidence_id")):
        errors.append(f"{label}.evidence_id")
    if not _is_sha256(value.get("content_sha256")):
        errors.append(f"{label}.content_sha256")


def _validate_lock_holder(value: Any, errors: list[str]) -> None:
    if not isinstance(value, dict):
        errors.append("lock_holder object required")
        return
    for field in ("boot_id", "process_identity", "fencing_token"):
        if not _is_nonempty_string(value.get(field)):
            errors.append(f"lock_holder.{field}")
    generation = value.get("acquisition_generation")
    if not isinstance(generation, int) or generation < 0:
        errors.append("lock_holder.acquisition_generation")


def _validate_recovery(value: Any, errors: list[str]) -> None:
    if not isinstance(value, dict):
        errors.append("recovery object required")
        return
    recovery_class = value.get("class")
    if recovery_class not in RECOVERY_CLASSES:
        errors.append("recovery.class")
        return
    if recovery_class == "NONE":
        return
    for field in (
        "forward_progress_permitted",
        "new_mutation_permitted",
        "release_permitted",
        "activation_permitted",
    ):
        if value.get(field) is not False:
            errors.append(f"recovery.{field}")
    if recovery_class == "MANUAL_RECOVERY_REQUIRED":
        if not _is_nonempty_string(value.get("reason_code")):
            errors.append("recovery.reason_code")
        return
    if not _is_nonempty_string(value.get("transaction_id")):
        errors.append("recovery.transaction_id")
    if not isinstance(value.get("participants"), list) or not value["participants"]:
        errors.append("recovery.participants")
    else:
        for participant in value["participants"]:
            if not isinstance(participant, dict):
                errors.append("recovery.participant")
                continue
            for field in ("manager", "object_id", "observed_generation"):
                if not _is_nonempty_string(participant.get(field)):
                    errors.append(f"recovery.participant.{field}")
            if not _is_sha256(participant.get("observed_fingerprint")):
                errors.append("recovery.participant.observed_fingerprint")
            if participant.get("rollback_outcome") not in ROLLBACK_OUTCOMES:
                errors.append("recovery.participant.rollback_outcome")


def validate_journal(document: Any) -> list[str]:
    errors = _check_schema(document, LIFECYCLE_JOURNAL_V1)
    if errors:
        return errors
    assert isinstance(document, dict)
    _append_missing(errors, document, ("transaction_id", "provenance", "records"))
    if not _is_nonempty_string(document.get("transaction_id")):
        errors.append("transaction_id")
    provenance = document.get("provenance")
    if not isinstance(provenance, dict) or not _COMMIT_RE.fullmatch(
        str(provenance.get("candidate_commit") or "")
    ):
        errors.append("provenance.candidate_commit")
    records = document.get("records")
    if not isinstance(records, list) or not records:
        errors.append("records")
        return errors

    expected_sequence = 1
    seen: set[int] = set()
    for record in records:
        if not isinstance(record, dict):
            errors.append("journal record object required")
            continue
        if record.get("schema_version") != LIFECYCLE_JOURNAL_V1:
            errors.append("fail-closed: unknown schema_version")
        sequence = record.get("sequence")
        if not isinstance(sequence, int) or sequence < 1:
            errors.append("sequence")
        else:
            if sequence in seen:
                errors.append("fail-closed: duplicate sequence")
            if sequence != expected_sequence:
                errors.append("fail-closed: out-of-order sequence")
            seen.add(sequence)
            expected_sequence += 1
        if record.get("transaction_id") != document.get("transaction_id"):
            errors.append("transaction_id mismatch")
        for field in ("operation_id", "step"):
            if not _is_nonempty_string(record.get(field)):
                errors.append(field)
        if record.get("idempotence_class") not in IDEMPOTENCE_CLASSES:
            errors.append("invalid idempotence_class")
        _validate_generation(record.get("expected_before"), "expected_before", errors)
        _validate_generation(record.get("expected_after"), "expected_after", errors)
        _validate_generation(
            record.get("effective_runtime_state"), "effective_runtime_state", errors
        )
        _validate_evidence(
            record.get("manager_prepare_evidence"), "manager_prepare_evidence", errors
        )
        _validate_evidence(
            record.get("manager_commit_evidence"), "manager_commit_evidence", errors
        )
        rollback = record.get("rollback")
        if not isinstance(rollback, dict):
            errors.append("rollback object required")
        else:
            if not _is_nonempty_string(rollback.get("reference")):
                errors.append("rollback.reference")
            if rollback.get("outcome") not in ROLLBACK_OUTCOMES:
                errors.append("rollback.outcome")
        _validate_lock_holder(record.get("lock_holder"), errors)
        _validate_recovery(record.get("recovery"), errors)

        supplied = record.get("integrity_sha256")
        if not _is_sha256(supplied):
            errors.append("fail-closed: missing integrity checksum")
        else:
            raw = copy.deepcopy(record)
            raw.pop("integrity_sha256", None)
            expected = hashlib.sha256(_canonical(raw)).hexdigest()
            if supplied != expected:
                errors.append("fail-closed: integrity mismatch")
    return errors


def parse_journal_payload(raw: str | bytes) -> tuple[dict[str, Any] | None, list[str]]:
    if raw in ("", b""):
        return None, ["fail-closed: torn or truncated record"]
    try:
        document = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError):
        return None, ["fail-closed: torn or truncated record"]
    if not isinstance(document, dict):
        return None, ["fail-closed: object required"]
    errors = validate_journal(document)
    return (None if errors else document), errors


def validate_mutation_envelope(envelope: Any) -> list[str]:
    errors = _check_schema(envelope, MUTATION_ENVELOPE_V1)
    if errors:
        return errors
    assert isinstance(envelope, dict)
    required = (
        "manager_name",
        "manager_schema_version",
        "transaction_id",
        "operation_id",
        "owned_objects",
        "expected_current",
        "proposed_next",
        "fencing_token",
        "prepare_evidence",
        "commit_evidence",
        "postcheck_evidence",
        "rollback_evidence",
        "mutation_gate",
        "security_v2_lock_order",
        "pure",
    )
    _append_missing(errors, envelope, required)
    for field in ("manager_name", "manager_schema_version", "transaction_id", "operation_id"):
        if not _is_nonempty_string(envelope.get(field)):
            errors.append(field)
    if not _is_nonempty_string(envelope.get("fencing_token")):
        errors.append("missing fencing_token")
    _validate_generation(envelope.get("expected_current"), "expected_current", errors)
    _validate_generation(envelope.get("proposed_next"), "proposed_next", errors)
    for field in (
        "prepare_evidence",
        "commit_evidence",
        "postcheck_evidence",
        "rollback_evidence",
    ):
        _validate_evidence(envelope.get(field), field, errors)
    objects = envelope.get("owned_objects")
    if not isinstance(objects, list) or not objects:
        errors.append("owned_objects")
    gate = envelope.get("mutation_gate")
    if not isinstance(gate, dict):
        errors.append("mutation_gate")
    else:
        if gate.get("context") != "lifecycle-transaction":
            errors.append("mutation_gate.context")
        if gate.get("execution") != "contract-only":
            errors.append("mutation_gate.execution")
        if not _is_nonempty_string(gate.get("gate_id")):
            errors.append("mutation_gate.gate_id")
    if tuple(envelope.get("security_v2_lock_order") or ()) != SECURITY_V2_LOCK_ORDER:
        errors.append("security_v2_lock_order")
    if envelope.get("pure") is not True:
        errors.append("pure")
    return errors


def _contains_banned_mutation_key(value: Any) -> bool:
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).lower() in _BANNED_MUTATION_KEYS:
                return True
            if _contains_banned_mutation_key(child):
                return True
    elif isinstance(value, list):
        return any(_contains_banned_mutation_key(item) for item in value)
    return False


def validate_verify_result(result: Any) -> list[str]:
    errors = _check_schema(result, VERIFY_RESULT_V1)
    if errors:
        return errors
    assert isinstance(result, dict)
    _append_missing(errors, result, ("policy_version", "policy_hash", "checks"))
    if not _is_nonempty_string(result.get("policy_version")):
        errors.append("policy_version")
    if not _is_sha256(result.get("policy_hash")):
        errors.append("policy_hash")
    if _contains_banned_mutation_key(result):
        errors.append("verify result contains mutation-capable field")
    checks = result.get("checks")
    if not isinstance(checks, list):
        errors.append("checks")
        return errors
    seen: set[str] = set()
    for check in checks:
        if not isinstance(check, dict):
            errors.append("malformed check")
            continue
        check_id = check.get("check_id")
        required_fields = (
            "check_id",
            "required",
            "configured",
            "observed_at",
            "freshness_ttl_seconds",
            "timeout_seconds",
            "evidence_source",
            "status",
            "reason_code",
        )
        if any(field not in check for field in required_fields):
            errors.append("malformed check")
            continue
        if not _is_nonempty_string(check_id):
            errors.append("malformed check")
            continue
        if check_id in seen:
            errors.append("duplicate check")
        seen.add(check_id)
        if type(check.get("required")) is not bool or type(check.get("configured")) is not bool:
            errors.append("malformed check")
        if check.get("status") not in VERIFY_STATUSES:
            errors.append("malformed check")
        if not _is_nonempty_string(check.get("evidence_source")):
            errors.append("malformed check")
        if not _is_nonempty_string(check.get("reason_code")):
            errors.append("malformed check")
        for field in ("freshness_ttl_seconds", "timeout_seconds"):
            if not isinstance(check.get(field), (int, float)) or check[field] < 0:
                errors.append("malformed check")
    return errors


def aggregate_verify(result: Any, policy: Any) -> dict[str, Any]:
    errors = validate_verify_result(result)
    if not isinstance(policy, dict):
        errors.append("fail-closed: verify policy required")
        return {"status": "UNKNOWN", "exit_code": 2, "success": False, "errors": errors}
    expected_hash = policy.get("policy_hash")
    if not _is_sha256(expected_hash) or result.get("policy_hash") != expected_hash:
        errors.append("fail-closed: verify_policy_hash_mismatch")
    required_ids = policy.get("required_check_ids")
    if not isinstance(required_ids, list) or not all(_is_nonempty_string(x) for x in required_ids):
        errors.append("fail-closed: invalid required_check_ids")
        required_ids = []

    checks_by_id: dict[str, dict[str, Any]] = {}
    if isinstance(result, dict) and isinstance(result.get("checks"), list):
        for check in result["checks"]:
            if isinstance(check, dict) and _is_nonempty_string(check.get("check_id")):
                checks_by_id[check["check_id"]] = check

    if errors:
        return {"status": "UNKNOWN", "exit_code": 2, "success": False, "errors": errors}

    required_fail = False
    required_unknown = False
    for check_id in required_ids:
        check = checks_by_id.get(check_id)
        if check is None:
            errors.append("missing required check")
            required_unknown = True
            continue
        if check.get("required") is not True:
            errors.append("malformed check")
            required_unknown = True
            continue
        status = check.get("status")
        if status == "FAIL":
            required_fail = True
        elif status == "UNKNOWN":
            required_unknown = True
        elif status == "NOT_CONFIGURED":
            errors.append("NOT_CONFIGURED not allowed")
            required_unknown = True

    for check in checks_by_id.values():
        if check.get("status") == "NOT_CONFIGURED" and (
            check.get("required") is True or check.get("configured") is not False
        ):
            if "NOT_CONFIGURED not allowed" not in errors:
                errors.append("NOT_CONFIGURED not allowed")
            required_unknown = True

    if required_fail:
        return {"status": "FAIL", "exit_code": 1, "success": False, "errors": errors}
    if required_unknown or errors:
        return {"status": "UNKNOWN", "exit_code": 2, "success": False, "errors": errors}
    return {"status": "PASS", "exit_code": 0, "success": True, "errors": []}


def validate_image_provenance(
    image: Any, *, expected_trust_policy_hash: str | None = None
) -> list[str]:
    errors = _check_schema(image, IMAGE_PROVENANCE_V1)
    if errors:
        return errors
    assert isinstance(image, dict)
    required = (
        "registry",
        "repository",
        "platform",
        "manifest_digest",
        "platform_digest",
        "running_image_id",
        "running_repo_digest",
        "trust_policy_version",
        "trust_policy_hash",
        "trust_basis",
        "lkg",
    )
    _append_missing(errors, image, required)
    for field in ("registry", "repository", "trust_policy_version"):
        if not _is_nonempty_string(image.get(field)):
            errors.append(field)
    platform = image.get("platform")
    if not isinstance(platform, dict) or not all(
        _is_nonempty_string(platform.get(field)) for field in ("os", "architecture")
    ):
        errors.append("platform")
    for field in (
        "manifest_digest",
        "platform_digest",
        "running_image_id",
        "running_repo_digest",
    ):
        if not _is_digest(image.get(field)):
            errors.append(f"missing {field}")
    if image.get("trust_basis") in (None, "", "mutable_tag"):
        errors.append("mutable-tag-only trust")
    if not _is_sha256(image.get("trust_policy_hash")):
        errors.append("trust_policy_hash")
    if expected_trust_policy_hash is not None and image.get(
        "trust_policy_hash"
    ) != expected_trust_policy_hash:
        errors.append("fail-closed: trust_policy_hash_mismatch")
    lkg = image.get("lkg")
    if not isinstance(lkg, dict):
        errors.append("lkg")
    else:
        if not _is_digest(lkg.get("image_id")):
            errors.append("lkg missing image_id")
        if not _is_digest(lkg.get("platform_digest")):
            errors.append("lkg missing platform_digest")
        if lkg.get("retention_protected") is not True:
            errors.append("lkg.retention_protected")
    return errors


def _secret_like_key(key: str) -> bool:
    lower = key.lower()
    if key in _ALLOWED_SECRET_KEYS:
        return False
    return any(
        marker in lower
        for marker in (
            "password",
            "token",
            "api_key",
            "apikey",
            "private_key",
            "secret",
            "credential",
            "cert_pem",
            "pem",
        )
    )


def _secret_like_value(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    if any(marker in value for marker in _SECRET_VALUE_MARKERS):
        return True
    return value.startswith("eyJ") and value.count(".") >= 2


def _scan_secret_evidence(value: Any, path: str = "") -> bool:
    if isinstance(value, dict):
        for key, child in value.items():
            if _secret_like_key(str(key)):
                return True
            if _scan_secret_evidence(child, f"{path}.{key}"):
                return True
    elif isinstance(value, list):
        return any(_scan_secret_evidence(item, path) for item in value)
    elif _secret_like_value(value):
        return True
    return False


def validate_secret_preflight(evidence: Any) -> list[str]:
    errors = _check_schema(evidence, SECRET_PREFLIGHT_V1)
    if errors:
        return errors
    assert isinstance(evidence, dict)
    required_bools = (
        "secret_present",
        "structure_valid",
        "certificate_chain_valid",
        "certificate_time_valid",
        "private_key_matches",
        "jwt_key_valid",
    )
    _append_missing(
        errors,
        evidence,
        (*required_bools, "failure_status", "failure_reason", "fingerprints"),
    )
    for field in required_bools:
        if type(evidence.get(field)) is not bool:
            errors.append(field)
    if evidence.get("failure_status") not in {"OK", "PRECHECK_FAILED"}:
        errors.append("failure_status")
    if not isinstance(evidence.get("failure_reason"), str):
        errors.append("failure_reason")
    fingerprints = evidence.get("fingerprints")
    if not isinstance(fingerprints, dict) or any(
        not _is_sha256(value) for value in fingerprints.values()
    ):
        errors.append("fingerprints")
    if _scan_secret_evidence(evidence):
        errors.append("secret-looking field")
    return errors


def validate_release_binding(binding: Any) -> list[str]:
    errors = _check_schema(binding, RELEASE_BINDING_V1)
    if errors:
        return errors
    assert isinstance(binding, dict)
    required = (
        "reviewed_candidate_commit",
        "source_blob_hashes",
        "artifact_hashes",
        "runtime_image_platform_digest",
        "verify_policy_hash",
        "trust_policy_hash",
        "review_evidence_ids",
        "release_approval_id",
        "activation_authorized",
    )
    _append_missing(errors, binding, required)
    if not _COMMIT_RE.fullmatch(str(binding.get("reviewed_candidate_commit") or "")):
        errors.append("reviewed_candidate_commit")
    for field in ("source_blob_hashes", "artifact_hashes"):
        value = binding.get(field)
        if not isinstance(value, dict) or not value or any(
            not _is_sha256(item) for item in value.values()
        ):
            errors.append(field)
    if not _is_digest(binding.get("runtime_image_platform_digest")):
        errors.append("runtime_image_platform_digest")
    for field in ("verify_policy_hash", "trust_policy_hash"):
        if not _is_sha256(binding.get(field)):
            errors.append(field)
    review_ids = binding.get("review_evidence_ids")
    if not isinstance(review_ids, list) or not review_ids or not all(
        _is_nonempty_string(item) for item in review_ids
    ):
        errors.append("review_evidence_ids")
    if not _is_nonempty_string(binding.get("release_approval_id")):
        errors.append("release_approval_id")
    if binding.get("activation_authorized") is not False:
        errors.append("activation_authorized")
    for key, value in binding.items():
        if key != "activation_authorized" and "activat" in key.lower() and value not in (
            None,
            False,
            "",
            [],
            {},
        ):
            errors.append("activation_authorized")
            break
    return errors


def policy_binding_result(
    binding: Any,
    *,
    observed_verify_policy_hash: str,
    observed_trust_policy_hash: str,
) -> dict[str, Any]:
    errors = validate_release_binding(binding)
    if isinstance(binding, dict):
        if binding.get("verify_policy_hash") != observed_verify_policy_hash:
            errors.append("fail-closed: verify_policy_hash_mismatch")
        if binding.get("trust_policy_hash") != observed_trust_policy_hash:
            errors.append("fail-closed: trust_policy_hash_mismatch")
    return {"accepted": not errors, "fail_closed": bool(errors), "errors": errors}
