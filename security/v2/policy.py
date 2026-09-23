"""Pure policy evaluation. Recommendations are advisory.

Mutating entry points refuse while FEATURE_AUTO_POLICY is hard-off. A future
automatic policy is a separate reviewed feature and is not enabled by config.
"""

from __future__ import annotations

from security.v2.contracts import POLICY_EVALUATION, assert_valid
from security.v2.flags import assert_auto_policy_blocked


def evaluate(current_state: dict, facts: list[dict]) -> dict:
    """Read-only. No file, firewall, transport, or egress side effects."""
    layers = []
    risk = "none"
    proposed = {"action": "hold"}
    for fact in facts:
        source = fact.get("source")
        if source in {"inbound", "transport", "egress"} and source not in layers:
            layers.append(source)
        if fact.get("severity") in {"high", "critical"}:
            risk = "high"
            proposed = {"action": "request_review", "fact": fact.get("dedup_key")}
        elif fact.get("severity") == "medium" and risk == "none":
            risk = "medium"
            proposed = {"action": "request_review", "fact": fact.get("dedup_key")}
    recommended = dict(current_state)
    if proposed["action"] == "request_review":
        recommended = {**current_state, "review": "pending"}
    rollback_id = current_state.get("transaction_id") or "none"
    doc = {
        "schema": POLICY_EVALUATION,
        "current_state": current_state,
        "recommended_state": recommended,
        "triggering_facts": [fact.get("dedup_key") for fact in facts],
        "target_layers": layers,
        "proposed_change": proposed,
        "risk": risk,
        "approval_required": True,
        "rollback_id": rollback_id,
        "pure": True,
    }
    return assert_valid(POLICY_EVALUATION, doc)


def apply_recommendation(base, evaluation: dict) -> dict:
    """Mutating path. Always refused in this candidate."""
    try:
        assert_auto_policy_blocked(base)
    except PermissionError as exc:
        return {
            "ok": False,
            "mutated": False,
            "reason": str(exc),
            "evaluation_schema": evaluation.get("schema"),
        }
    return {"ok": False, "mutated": False, "reason": "auto_policy_off"}
