"""Optional Remnawave node-plugin contract.

The plugin is application-aware and is never a second host ingress filter.
This candidate stores the contract only.
"""

from __future__ import annotations

from security.v2.contracts import NODE_PLUGIN, assert_valid


def contract(enabled: bool = False) -> dict:
    doc = {
        "schema": NODE_PLUGIN,
        "enabled": enabled,
        "authoritative_ingress": False,
        "mode": "optional",
        "observes": ["node_api_health"],
        "mutates_host_firewall": False,
    }
    return assert_valid(NODE_PLUGIN, doc)


def reject_authoritative(doc: dict) -> dict:
    if doc.get("authoritative_ingress") is True:
        raise ValueError("node plugin cannot own host ingress")
    return contract(bool(doc.get("enabled", False)))
