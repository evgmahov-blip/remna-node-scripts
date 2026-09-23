"""Offline V2 commands. Refuses implicit production paths and live activation."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from security.v2.flags import evaluate_flags, write_flags
from security.v2.policy import apply_recommendation, evaluate
from security.v2.xray_contract import activation_plan, activation_result

FORBIDDEN_PREFIXES = ("/opt/ainoc", "/opt/ainoc-projects")


def resolve_base(text: str) -> Path:
    if not text:
        raise SystemExit("refusing implicit base; pass --base")
    path = Path(text).resolve()
    for prefix in FORBIDDEN_PREFIXES:
        if str(path) == prefix or str(path).startswith(prefix + "/"):
            raise SystemExit("refusing to touch " + prefix)
    node_base = "/opt/remna-protection"
    if str(path) == node_base or str(path).startswith(node_base + "/"):
        if os.environ.get("REMNA_V2_ALLOW_NODE_BASE") != "1":
            raise SystemExit("refusing the node protection base in this candidate")
    return path


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="remna-security-v2")
    sub = parser.add_subparsers(dest="cmd", required=True)
    flags = sub.add_parser("flags")
    flags.add_argument("--base", required=True)
    flags.add_argument("--set", action="append", default=[])
    policy = sub.add_parser("policy-evaluate")
    policy.add_argument("--current", required=True)
    policy.add_argument("--facts", required=True)
    apply = sub.add_parser("policy-apply")
    apply.add_argument("--base", required=True)
    apply.add_argument("--evaluation", required=True)
    plan = sub.add_parser("activation-plan")
    plan.add_argument("--reload-method", default="unknown")
    sub.add_parser("activation-result")
    args = parser.parse_args(argv)
    if args.cmd == "flags":
        base = resolve_base(args.base)
        if args.set:
            configured = {}
            for item in args.set:
                key, value = item.split("=", 1)
                configured[key] = int(value)
            doc = write_flags(base, configured)
        else:
            doc = evaluate_flags(base)
        json.dump(doc, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0 if doc["validation"]["ok"] else 1
    if args.cmd == "policy-evaluate":
        current = json.loads(Path(args.current).read_text(encoding="utf-8"))
        facts = json.loads(Path(args.facts).read_text(encoding="utf-8"))
        json.dump(evaluate(current, facts), sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    if args.cmd == "policy-apply":
        base = resolve_base(args.base)
        evaluation = json.loads(Path(args.evaluation).read_text(encoding="utf-8"))
        result = apply_recommendation(base, evaluation)
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0 if result.get("mutated") else 2
    if args.cmd == "activation-plan":
        doc = activation_plan(args.reload_method)
        json.dump(doc, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0 if not doc["refused"] else 2
    if args.cmd == "activation-result":
        json.dump(activation_result(), sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
