"""Machine-readable Remna Security V2 contracts.

Evaluation objects are pure data. Nothing in this module mutates runtime state.
"""

from __future__ import annotations

import json
from pathlib import Path

SCHEMA_DIR = Path(__file__).resolve().parent / "schemas"

DETECTOR_FACT = "remna-security.detector-fact.v1"
POLICY_EVALUATION = "remna-security.policy-evaluation.v1"
LAYER_GENERATION = "remna-security.layer-generation.v1"
FEATURE_FLAGS = "remna-security.feature-flags.v1"
WARP_STATUS = "remna-security.warp-status.v1"
ENDPOINT_HEALTH = "remna-security.endpoint-health.v1"
QUIC_PROFILE = "remna-security.quic-noise-profile.v1"
XRAY_ACTIVATION_PLAN = "remna-security.xray-activation-plan.v1"
XRAY_ACTIVATION_RESULT = "remna-security.xray-activation-result.v1"
SCANNER_CATALOG = "remna-security.scanner-catalog.v1"
DECOY_STATUS = "remna-security.decoy-status.v1"
NODE_PLUGIN = "remna-security.node-plugin.v1"

LAYERS = ("inbound", "transport", "egress")
SEVERITIES = ("info", "low", "medium", "high", "critical")
FACT_SOURCES = ("inbound", "transport", "egress", "operator", "scanner", "health")
ENDPOINT_ORIGINS = ("configured", "lkg", "registration", "discovered")
TRUST_RANK = {"configured": 0, "lkg": 1, "registration": 2, "discovered": 3}

SECRET_FIELDS = {
    "private_key",
    "privateKey",
    "secret_key",
    "secretKey",
    "token",
    "bearer",
    "bearer_token",
    "authorization",
    "auth_header",
    "account_id",
    "provider_account_id",
}


def load_schema(name: str) -> dict:
    path = SCHEMA_DIR / f"{name}.json"
    return json.loads(path.read_text(encoding="utf-8"))


def _fail(errors: list[str], message: str) -> None:
    errors.append(message)


def _require(doc: dict, fields: tuple[str, ...], errors: list[str]) -> None:
    for field in fields:
        if field not in doc:
            _fail(errors, f"missing {field}")


def _typ(doc: dict, field: str, kind: type | tuple[type, ...], errors: list[str]) -> None:
    if field in doc and not isinstance(doc[field], kind):
        _fail(errors, f"{field} type")


def validate_contract(kind: str, doc: dict) -> list[str]:
    errors: list[str] = []
    if not isinstance(doc, dict):
        return ["document must be an object"]
    if doc.get("schema") != kind:
        _fail(errors, f"schema {doc.get('schema')!r} != {kind}")
    if kind == DETECTOR_FACT:
        _require(doc, ("observed_at", "source", "severity", "confidence", "ttl_seconds", "dedup_key", "occurrence_count"), errors)
        _typ(doc, "observed_at", int, errors)
        _typ(doc, "ttl_seconds", int, errors)
        _typ(doc, "occurrence_count", int, errors)
        _typ(doc, "confidence", (int, float), errors)
        _typ(doc, "dedup_key", str, errors)
        if doc.get("source") not in FACT_SOURCES:
            _fail(errors, "source")
        if doc.get("severity") not in SEVERITIES:
            _fail(errors, "severity")
        if isinstance(doc.get("confidence"), (int, float)) and not 0 <= float(doc["confidence"]) <= 1:
            _fail(errors, "confidence range")
        if isinstance(doc.get("ttl_seconds"), int) and doc["ttl_seconds"] <= 0:
            _fail(errors, "ttl_seconds")
        if isinstance(doc.get("occurrence_count"), int) and doc["occurrence_count"] < 1:
            _fail(errors, "occurrence_count")
    elif kind == POLICY_EVALUATION:
        _require(
            doc,
            (
                "current_state",
                "recommended_state",
                "triggering_facts",
                "target_layers",
                "proposed_change",
                "risk",
                "approval_required",
                "rollback_id",
                "pure",
            ),
            errors,
        )
        if doc.get("pure") is not True:
            _fail(errors, "evaluation must be pure")
        if doc.get("approval_required") is not True:
            _fail(errors, "approval_required")
        layers = doc.get("target_layers")
        if not isinstance(layers, list) or any(layer not in LAYERS for layer in layers):
            _fail(errors, "target_layers")
        if doc.get("risk") not in ("none", "low", "medium", "high"):
            _fail(errors, "risk")
    elif kind == LAYER_GENERATION:
        _require(doc, ("layer", "generation_id", "transaction_id", "content_sha256", "rollback_owner"), errors)
        if doc.get("layer") not in LAYERS:
            _fail(errors, "layer")
        if doc.get("rollback_owner") != doc.get("layer"):
            _fail(errors, "rollback owner must be the same layer")
    elif kind == FEATURE_FLAGS:
        _require(doc, ("configured", "effective", "validation", "auto_policy_hard_off"), errors)
        if doc.get("auto_policy_hard_off") is not True:
            _fail(errors, "auto_policy_hard_off")
        effective = doc.get("effective") or {}
        if effective.get("FEATURE_AUTO_POLICY") != 0:
            _fail(errors, "effective AUTO_POLICY must be 0")
    elif kind == WARP_STATUS:
        _require(doc, ("schema", "registered", "redacted", "orphan_risk", "has_lkg"), errors)
        if doc.get("redacted") is not True:
            _fail(errors, "redacted")
        blob = json.dumps(doc)
        for marker in ("private_key", "bearer ", "Authorization:", "secretKey"):
            if marker in blob:
                _fail(errors, f"secret marker {marker}")
    elif kind == ENDPOINT_HEALTH:
        _require(doc, ("endpoint", "origin", "status", "success_streak", "failure_streak"), errors)
        if doc.get("origin") not in ENDPOINT_ORIGINS:
            _fail(errors, "origin")
        if doc.get("status") not in ("unknown", "candidate", "healthy", "demoted", "cooldown"):
            _fail(errors, "status")
    elif kind == QUIC_PROFILE:
        _require(doc, ("profile_id", "version", "immutable", "content_hash", "packet_size"), errors)
        if doc.get("immutable") is not True:
            _fail(errors, "profile must be immutable")
        if not isinstance(doc.get("content_hash"), str) or len(doc.get("content_hash", "")) != 64:
            _fail(errors, "content_hash")
    elif kind == XRAY_ACTIVATION_PLAN:
        _require(doc, ("stages", "reload_method", "execute", "refused"), errors)
        if doc.get("execute") is not False:
            _fail(errors, "plan must not execute in this candidate")
        stages = doc.get("stages")
        needed = [
            "candidate_temp_file",
            "syntax_semantic_validation",
            "rw_core_run_test",
            "snapshot",
            "atomic_rename",
            "reload_or_restart",
            "end_to_end_verification",
            "rollback_on_failure",
        ]
        if stages != needed:
            _fail(errors, "activation stages")
        if doc.get("reload_method") == "SIGHUP":
            _fail(errors, "SIGHUP is not an activation method")
    elif kind == XRAY_ACTIVATION_RESULT:
        _require(doc, ("activated", "stage_reached", "rolled_back"), errors)
        if doc.get("activated") is not False:
            _fail(errors, "activation result must stay inactive")
    elif kind == SCANNER_CATALOG:
        _require(doc, ("categories", "default_enabled"), errors)
        cats = {item.get("id") for item in doc.get("categories") or []}
        for name in ("tspu", "gov", "censys", "shodan", "shadowserver", "rapid7", "zoomeye", "leakix", "onyphe", "fofa", "quake"):
            if name not in cats:
                _fail(errors, f"missing category {name}")
    elif kind == DECOY_STATUS:
        _require(doc, ("seed", "generation", "runtime_trackers", "external_assets"), errors)
        if doc.get("runtime_trackers") is not False or doc.get("external_assets") is not False:
            _fail(errors, "decoy runtime must default off")
    elif kind == NODE_PLUGIN:
        _require(doc, ("enabled", "authoritative_ingress", "mode"), errors)
        if doc.get("authoritative_ingress") is not False:
            _fail(errors, "plugin must not be an authoritative ingress filter")
    else:
        _fail(errors, "unknown schema")
    return errors


def assert_valid(kind: str, doc: dict) -> dict:
    errors = validate_contract(kind, doc)
    if errors:
        raise ValueError(kind + ": " + "; ".join(errors))
    return doc


def redact(value, parent_key: str = ""):
    """Drop secret-shaped fields. Account ids are omitted, not hashed into the status."""
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if key in SECRET_FIELDS or key.lower() in {"authorization", "private_key", "token"}:
                continue
            out[key] = redact(item, key)
        return out
    if isinstance(value, list):
        return [redact(item, parent_key) for item in value]
    if isinstance(value, str) and parent_key.lower() in {"authorization", "token"}:
        return None
    return value
