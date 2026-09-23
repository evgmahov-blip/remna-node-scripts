#!/usr/bin/env python3
"""RemnaNode Security core.

Validates feeds, renders owned firewall plans, applies them to a simulator or
to a live host, and emits the stable JSON contract. Live execution is refused
when REMNA_SECURITY_FORBID_LIVE=1.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

SCHEMA_STATUS = "remna-security.status.v1"
SCHEMA_PREFLIGHT = "remna-security.preflight.v1"
SCHEMA_UPDATE = "remna-security.update.v1"
SCHEMA_SELFTEST = "remna-security.selftest.v1"

CHAIN = "REMNA_GUARD"
CHAIN6 = "REMNA_GUARD6"
NFT_TABLE = "remna_security"
NFT_FAMILY = "inet"
SET_TSPU = "REMNA_TSPU"
SET_GOV = "REMNA_GOV"
SET_ALLOW = "REMNA_ALLOW"
SET_DENY = "REMNA_DENY"
SET_COUNTRY = "REMNA_COUNTRY_ALLOW"
SET_SCANNERS = "REMNA_SCANNERS"

SOURCE_META = {
    "tspu": {"class": "pinned", "mode": "plain", "family": "ipv4", "min_absolute": 1, "set": SET_TSPU, "maxelem": 2000000},
    "gov": {"class": "pinned", "mode": "gov", "family": "ipv4", "min_absolute": 1, "set": SET_GOV, "maxelem": 2000000},
    "scanners": {"class": "fast", "mode": "plain", "family": "ipv4", "min_absolute": 1, "set": SET_SCANNERS, "maxelem": 2000000},
    "geoip": {"class": "pinned", "mode": "plain", "family": "ipv4", "min_absolute": 10, "set": SET_COUNTRY, "maxelem": 3000000},
}

DEFAULTS = {
    "PANEL_IP": "",
    "ENABLE_TSPU": "1",
    "ENABLE_GOV": "1",
    "ENABLE_GEOIP": "0",
    "ENABLE_SCANNERS": "0",
    "FILTER_PORTS": "443",
    "GEO_COUNTRIES": "",
    "SCANNER_URL": "",
    "BACKEND": "iptables",
    "LOG_DROPS": "0",
}

V4_RE = re.compile(r"(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?")
V6_RE = re.compile(r"(?:[0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F:]*(?:/\d{1,3})?")
GOV_HEADER = {"create", "flush", "destroy", "swap", "list", "header"}


def env_flag(name: str) -> bool:
    return os.environ.get(name, "0") == "1"


def anomaly_params():
    return (
        int(os.environ.get("REMNA_ANOMALY_MIN_BASE", "50")),
        float(os.environ.get("REMNA_MAX_GROWTH_RATIO", "5")),
        float(os.environ.get("REMNA_MIN_SHRINK_RATIO", "0.2")),
    )


def git_blob_sha1(data: bytes) -> str:
    header = f"blob {len(data)}\0".encode()
    return hashlib.sha1(header + data).hexdigest()


def load_settings(base: Path) -> dict:
    cfg = dict(DEFAULTS)
    path = base / "settings.conf"
    if not path.exists():
        return cfg
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        cfg[key] = value
    return cfg


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    out = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        s = raw.strip()
        if s and not s.startswith("#"):
            out.append(s)
    return out


def looks_html(data: bytes) -> bool:
    head = data[:1024].lower()
    markers = (b"<!doctype", b"<html", b"<head", b"<body", b"<title")
    return any(m in head for m in markers)


def parse_network(token: str):
    return ipaddress.ip_network(token, strict=False)


def validate_feed(raw: bytes, mode: str, family: str, previous: list[str], panel: str, allow: list[str], min_absolute: int) -> dict:
    report = {
        "ok": False,
        "reason": "",
        "accepted": 0,
        "previous": len(previous),
        "panel_collisions": 0,
        "whitelist_collisions": 0,
        "malformed": 0,
        "family": family,
        "entries": [],
    }
    if looks_html(raw):
        report["reason"] = "html"
        return report
    text = raw.decode("utf-8", errors="replace")
    parsed = []
    malformed = 0
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        first = line.split()[0].lower()
        if mode == "gov" and first in GOV_HEADER and not V4_RE.search(line) and not V6_RE.search(line):
            continue
        if family == "ipv4" and V6_RE.search(line):
            report["reason"] = "family"
            return report
        if mode == "gov":
            found = V4_RE.findall(line)
            if not found:
                malformed += 1
                continue
            token = found[0]
        else:
            token = line.split()[0]
        try:
            net = parse_network(token)
        except Exception:
            malformed += 1
            continue
        if family == "ipv4" and net.version != 4:
            report["reason"] = "family"
            return report
        if net.version == 4 and net.prefixlen < 8:
            report["reason"] = "broad"
            report["example"] = str(net)
            return report
        parsed.append(net)
    report["malformed"] = malformed
    if malformed:
        report["reason"] = "malformed"
        return report
    uniq = sorted(set(parsed), key=lambda n: (int(n.network_address), n.prefixlen))
    if not uniq:
        report["reason"] = "empty"
        return report
    min_base, max_growth, min_ratio = anomaly_params()
    prev_nets = []
    for item in previous:
        try:
            prev_nets.append(parse_network(item))
        except Exception:
            continue
    prev_count = len(set(prev_nets))
    report["previous"] = prev_count
    if prev_count >= min_base:
        if len(uniq) > prev_count * max_growth:
            report["reason"] = "anomaly_huge"
            report["accepted"] = len(uniq)
            return report
        if len(uniq) < prev_count * min_ratio:
            report["reason"] = "anomaly_tiny"
            report["accepted"] = len(uniq)
            return report
    if len(uniq) < min_absolute:
        report["reason"] = "below_minimum"
        report["accepted"] = len(uniq)
        return report
    protected_panel = []
    protected_allow = []
    if panel:
        try:
            token = panel if "/" in panel else panel + "/32"
            protected_panel.append(parse_network(token))
        except Exception:
            report["reason"] = "malformed"
            return report
    for item in allow:
        try:
            protected_allow.append(parse_network(item if "/" in item else item + "/32"))
        except Exception:
            continue
    kept = []
    for net in uniq:
        if any(net.overlaps(p) for p in protected_panel):
            report["panel_collisions"] += 1
            continue
        if any(net.overlaps(a) for a in protected_allow):
            report["whitelist_collisions"] += 1
            continue
        kept.append(str(net))
    if not kept:
        report["reason"] = "whitelist_or_panel_removed_all"
        return report
    report["ok"] = True
    report["reason"] = "ok"
    report["accepted"] = len(kept)
    report["entries"] = kept
    return report


def default_state() -> dict:
    return {
        "input": ["-A INPUT -p tcp --dport 22 -j ACCEPT", "-A INPUT -j DOCKER-USER"],
        "input6": ["-A INPUT -p tcp --dport 22 -j ACCEPT"],
        "docker_chains": ["DOCKER", "DOCKER-USER"],
        "ufw_active": False,
        "ufw_rules": ["22/tcp ALLOW IN Anywhere"],
        "detected": "iptables-nft",
        "sets": {},
        "chains": {},
        "chains6": {},
        "nft_table": "",
        "owned_backend": "",
        "counters": {"node_api": 0, "tspu": 0, "gov": 0, "deny": 0, "geo_default": 0, "scanners": 0},
        "units": {},
        "last_commands": [],
        "nft_available": True,
    }


def state_path(base: Path) -> Path:
    return base / "sim" / "state.json"


def load_state(base: Path) -> dict:
    path = state_path(base)
    state = default_state()
    if path.exists():
        disk = json.loads(path.read_text(encoding="utf-8"))
        state.update(disk)
    return state


def save_state(base: Path, state: dict) -> None:
    path = state_path(base)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def seed_state(base: Path, profile: str) -> None:
    state = default_state()
    if profile == "isolated":
        state["docker_chains"] = []
        state["input"] = ["-A INPUT -p tcp --dport 22 -j ACCEPT"]
        state["ufw_active"] = False
        state["ufw_rules"] = ["22/tcp ALLOW IN Anywhere"]
    elif profile == "ufw":
        state["ufw_active"] = True
        state["ufw_rules"] = ["22/tcp ALLOW IN Anywhere", "2222/tcp ALLOW IN Anywhere"]
        state["docker_chains"] = ["DOCKER", "DOCKER-USER"]
    elif profile == "docker":
        pass
    else:
        raise SystemExit(f"unknown profile {profile}")
    save_state(base, state)


def is_jump(rule: str, chain: str) -> bool:
    parts = rule.split()
    if "-j" not in parts:
        return False
    return parts[parts.index("-j") + 1] == chain


def retarget(rules: list[str], chain: str) -> list[str]:
    kept = [r for r in rules if not is_jump(r, chain)]
    kept.insert(0, f"-A INPUT -j {chain}")
    return kept


def drop_jump(rules: list[str], chain: str) -> list[str]:
    return [r for r in rules if not is_jump(r, chain)]


def data_file(base: Path, name: str) -> Path:
    staging = base / "staging" / f"{name}.txt"
    if staging.exists():
        return staging
    return base / "data" / f"{name}.txt"


def split_families(entries: list[str]) -> tuple[list[str], list[str]]:
    v4, v6 = [], []
    for item in entries:
        try:
            net = parse_network(item)
        except Exception:
            continue
        if net.version == 4:
            v4.append(str(net))
        else:
            v6.append(str(net))
    return v4, v6


def protected_networks(cfg: dict, allow: list[str]) -> list:
    nets = []
    panel = cfg.get("PANEL_IP", "")
    if panel:
        try:
            nets.append(parse_network(panel if "/" in panel else panel + "/32"))
        except Exception:
            pass
    for item in allow:
        try:
            nets.append(parse_network(item if "/" in item else item + "/32"))
        except Exception:
            pass
    return nets


def subtract(entries: list[str], protected: list) -> tuple[list[str], int]:
    kept = []
    removed = 0
    for item in entries:
        try:
            net = parse_network(item)
        except Exception:
            continue
        if any(net.overlaps(p) for p in protected):
            removed += 1
            continue
        kept.append(str(net))
    return kept, removed


def ports_of(cfg: dict) -> list[int]:
    vals = []
    for part in cfg.get("FILTER_PORTS", "").split(","):
        part = part.strip()
        if not part:
            continue
        vals.append(int(part))
    return vals


def valid_ports(cfg: dict) -> bool:
    try:
        vals = ports_of(cfg)
    except Exception:
        return False
    return bool(vals) and len(vals) <= 15 and all(1 <= p <= 65535 for p in vals)


def valid_ip(value: str) -> bool:
    try:
        ipaddress.ip_address(value)
        return True
    except Exception:
        return False


def panel_version(cfg: dict) -> int:
    try:
        return ipaddress.ip_address(cfg.get("PANEL_IP", "")).version
    except Exception:
        return 0


def build_plan(base: Path) -> dict:
    cfg = load_settings(base)
    allow = read_lines(data_file(base, "allow"))
    deny = read_lines(data_file(base, "deny"))
    protected = protected_networks(cfg, allow)
    deny, deny_removed = subtract(deny, protected)
    sets = {}
    mapping = {
        "tspu": (cfg.get("ENABLE_TSPU") == "1", SET_TSPU),
        "gov": (cfg.get("ENABLE_GOV") == "1", SET_GOV),
        "scanners": (cfg.get("ENABLE_SCANNERS") == "1", SET_SCANNERS),
        "geoip": (cfg.get("ENABLE_GEOIP") == "1", SET_COUNTRY),
    }
    collisions = deny_removed
    for key, (enabled, set_name) in mapping.items():
        entries = read_lines(data_file(base, key if key != "geoip" else "countries"))
        if key == "geoip":
            entries = read_lines(data_file(base, "countries"))
        v4, _v6 = split_families(entries)
        if key != "geoip":
            v4, removed = subtract(v4, protected)
            collisions += removed
        meta = SOURCE_META[key]
        sets[set_name] = {"entries": v4 if enabled or v4 else v4, "maxelem": meta["maxelem"], "enabled": enabled, "entries_effective": v4}
    allow_v4, allow_v6 = split_families(allow)
    deny_v4, deny_v6 = split_families(deny)
    sets[SET_ALLOW] = {"entries": allow_v4, "maxelem": 65536, "enabled": True, "entries_effective": allow_v4}
    sets[SET_DENY] = {"entries": deny_v4, "maxelem": 65536, "enabled": True, "entries_effective": deny_v4}
    ports = ports_of(cfg) if valid_ports(cfg) else []
    port_csv = ",".join(str(p) for p in ports)
    panel = cfg.get("PANEL_IP", "")
    pver = panel_version(cfg)
    v4_rules = []
    if pver == 4:
        v4_rules.append(f"-A {CHAIN} -p tcp -s {panel} --dport 2222 -j ACCEPT")
    v4_rules.append(f"-A {CHAIN} -p tcp --dport 2222 -m comment --comment remna:node-api -j DROP")
    v4_rules.append(f"-A {CHAIN} -m set --match-set {SET_ALLOW} src -j ACCEPT")
    v4_rules.append(f"-A {CHAIN} -m set --match-set {SET_DENY} src -m comment --comment remna:deny -j DROP")
    log_drops = cfg.get("LOG_DROPS") == "1"

    def add_drop(set_name: str, tag: str) -> None:
        if log_drops:
            v4_rules.append(
                f"-A {CHAIN} -p tcp -m multiport --dports {port_csv} -m set --match-set {set_name} src "
                f"-m limit --limit 6/min --limit-burst 5 -j LOG --log-prefix REMNA-DROP:{tag} "
            )
        v4_rules.append(
            f"-A {CHAIN} -p tcp -m multiport --dports {port_csv} -m set --match-set {set_name} src "
            f"-m comment --comment remna:{tag} -j DROP"
        )

    if cfg.get("ENABLE_TSPU") == "1":
        add_drop(SET_TSPU, "tspu")
    if cfg.get("ENABLE_GOV") == "1":
        add_drop(SET_GOV, "gov")
    if cfg.get("ENABLE_SCANNERS") == "1":
        add_drop(SET_SCANNERS, "scanners")
    if cfg.get("ENABLE_GEOIP") == "1" and sets[SET_COUNTRY]["entries_effective"]:
        v4_rules.append(
            f"-A {CHAIN} -p tcp -m multiport --dports {port_csv} -m set --match-set {SET_COUNTRY} src -j ACCEPT"
        )
        if log_drops:
            v4_rules.append(
                f"-A {CHAIN} -p tcp -m multiport --dports {port_csv} -m limit --limit 6/min --limit-burst 5 "
                f"-j LOG --log-prefix REMNA-DROP:geo "
            )
        v4_rules.append(
            f"-A {CHAIN} -p tcp -m multiport --dports {port_csv} -m comment --comment remna:geo-default -j DROP"
        )
    v4_rules.append(f"-A {CHAIN} -j RETURN")
    backend = cfg.get("BACKEND", "iptables")
    if backend not in ("iptables", "nftables"):
        backend = "iptables"
    v6_rules = []
    if pver == 6:
        v6_rules.append(f"-A {CHAIN6} -p tcp -s {panel} --dport 2222 -j ACCEPT")
    v6_rules.append(f"-A {CHAIN6} -p tcp --dport 2222 -m comment --comment remna:node-api -j DROP")
    # IPv6 manual sets are enforced only by the nftables backend. The iptables
    # backend keeps the IPv6 node-api chain and does not pretend to load v6 feeds.
    if backend == "nftables" and allow_v6:
        v6_rules.append(f"-A {CHAIN6} -m set --match-set {SET_ALLOW}6 src -j ACCEPT")
    if backend == "nftables" and deny_v6:
        v6_rules.append(f"-A {CHAIN6} -m set --match-set {SET_DENY}6 src -j DROP")
    v6_rules.append(f"-A {CHAIN6} -j RETURN")
    plan = {
        "backend": backend,
        "panel_ip": panel,
        "panel_version": pver,
        "ports": ports,
        "sets": {name: meta["entries_effective"] for name, meta in sets.items()},
        "set_limits": {name: meta["maxelem"] for name, meta in sets.items()},
        "ipv4_rules": v4_rules,
        "ipv6_rules": v6_rules,
        "allow_v6": allow_v6,
        "deny_v6": deny_v6,
        "render_collisions": collisions,
        "log_drops": log_drops,
        "ipv6_dynamic_lists": False,
    }
    plan["nft"] = render_nft(plan)
    plan["ruleset_hash"] = hashlib.sha256(
        json.dumps(
            {
                "backend": plan["backend"],
                "sets": plan["sets"],
                "ipv4_rules": plan["ipv4_rules"],
                "ipv6_rules": plan["ipv6_rules"],
                "nft": plan["nft"],
            },
            sort_keys=True,
        ).encode()
    ).hexdigest()
    return plan


def nft_set_block(name: str, family: str, entries: list[str]) -> str:
    addr = "ipv4_addr" if family == "ip" else "ipv6_addr"
    body = ", ".join(entries)
    if body:
        return f"        set {name} {{ type {addr}; flags interval; auto-merge; elements = {{ {body} }} }}\n"
    return f"        set {name} {{ type {addr}; flags interval; auto-merge; }}\n"


def render_nft(plan: dict) -> str:
    ports = ", ".join(str(p) for p in plan["ports"]) or "443"
    lines = [f"table {NFT_FAMILY} {NFT_TABLE} {{\n"]
    for name in (SET_TSPU, SET_GOV, SET_SCANNERS, SET_ALLOW, SET_DENY, SET_COUNTRY):
        lines.append(nft_set_block(name, "ip", plan["sets"].get(name, [])))
    if plan["allow_v6"]:
        lines.append(nft_set_block("allow6", "ip6", plan["allow_v6"]))
    if plan["deny_v6"]:
        lines.append(nft_set_block("deny6", "ip6", plan["deny_v6"]))
    lines.append("        chain guard {\n")
    lines.append("                type filter hook input priority -10; policy accept;\n")
    if plan["panel_version"] == 4 and plan["panel_ip"]:
        lines.append(f"                tcp dport 2222 ip saddr {plan['panel_ip']} accept\n")
    if plan["panel_version"] == 6 and plan["panel_ip"]:
        lines.append(f"                tcp dport 2222 ip6 saddr {plan['panel_ip']} accept\n")
    lines.append('                tcp dport 2222 drop comment "remna:node-api"\n')
    lines.append(f"                ip saddr @{SET_ALLOW} accept\n")
    lines.append(f'                ip saddr @{SET_DENY} drop comment "remna:deny"\n')
    rules = "\n".join(plan["ipv4_rules"])
    if f"remna:tspu" in rules:
        lines.append(f'                tcp dport {{ {ports} }} ip saddr @{SET_TSPU} drop comment "remna:tspu"\n')
    if "remna:gov" in rules:
        lines.append(f'                tcp dport {{ {ports} }} ip saddr @{SET_GOV} drop comment "remna:gov"\n')
    if "remna:scanners" in rules:
        lines.append(f'                tcp dport {{ {ports} }} ip saddr @{SET_SCANNERS} drop comment "remna:scanners"\n')
    if "remna:geo-default" in rules:
        lines.append(f"                tcp dport {{ {ports} }} ip saddr @{SET_COUNTRY} accept\n")
        lines.append(f'                tcp dport {{ {ports} }} drop comment "remna:geo-default"\n')
    if plan["allow_v6"]:
        lines.append("                ip6 saddr @allow6 accept\n")
    if plan["deny_v6"]:
        lines.append('                ip6 saddr @deny6 drop comment "remna:deny6"\n')
    lines.append("        }\n")
    lines.append("}\n")
    return "".join(lines)


def nft_activation_block(state: dict, sim: bool) -> str:
    if state.get("ufw_active"):
        return "nftables_hook_would_bypass_ufw"
    if state.get("docker_chains"):
        return "nftables_hook_would_bypass_docker"
    if sim and not state.get("nft_available", True):
        return "nft_userspace_missing"
    if not sim and shutil.which("nft") is None:
        return "nft_userspace_missing"
    return ""


def build_commands(plan: dict, retire_nft: bool, retire_iptables: bool) -> list[list[str]]:
    cmds: list[list[str]] = []
    if plan["backend"] == "iptables":
        restore = []
        for name, entries in plan["sets"].items():
            limit = plan["set_limits"][name]
            tmp = f"{name}_TMP"
            restore.append(f"create {tmp} hash:net family inet maxelem {limit} -exist")
            restore.append(f"flush {tmp}")
            for entry in entries:
                restore.append(f"add {tmp} {entry}")
            restore.append(f"create {name} hash:net family inet maxelem {limit} -exist")
            restore.append(f"swap {tmp} {name}")
            restore.append(f"destroy {tmp}")
        if plan["allow_v6"] or plan["deny_v6"]:
            pass
        cmds.append(["ipset", "restore"])
        plan["ipset_restore"] = "\n".join(restore) + "\n"
        cmds.append(["iptables", "-N", CHAIN])
        cmds.append(["iptables", "-F", CHAIN])
        for rule in plan["ipv4_rules"]:
            cmds.append(["iptables", *rule.split()])
        cmds.append(["ip6tables", "-N", CHAIN6])
        cmds.append(["ip6tables", "-F", CHAIN6])
        for rule in plan["ipv6_rules"]:
            cmds.append(["ip6tables", *rule.split()])
        cmds.append(["iptables", "-D", "INPUT", "-j", CHAIN])
        cmds.append(["iptables", "-I", "INPUT", "1", "-j", CHAIN])
        cmds.append(["ip6tables", "-D", "INPUT", "-j", CHAIN6])
        cmds.append(["ip6tables", "-I", "INPUT", "1", "-j", CHAIN6])
        if retire_nft:
            cmds.append(["nft", "delete", "table", NFT_FAMILY, NFT_TABLE])
    else:
        cmds.append(["nft", "-f", "-"])
        plan["nft_payload"] = plan["nft"]
        if retire_iptables:
            cmds.append(["iptables", "-D", "INPUT", "-j", CHAIN])
            cmds.append(["iptables", "-F", CHAIN])
            cmds.append(["iptables", "-X", CHAIN])
            cmds.append(["ip6tables", "-D", "INPUT", "-j", CHAIN6])
            cmds.append(["ip6tables", "-F", CHAIN6])
            cmds.append(["ip6tables", "-X", CHAIN6])
            for name in plan["sets"]:
                cmds.append(["ipset", "destroy", name])
    return cmds


def ufw_commands(plan: dict, ufw_active: bool, ufw_rules: list[str]) -> list[list[str]]:
    if not ufw_active:
        return []
    cmds = [["ufw", "status"]]
    wide = [r for r in ufw_rules if r.startswith("2222/tcp") and "Anywhere" in r and "from" not in r.lower()]
    for _ in wide:
        cmds.append(["ufw", "--force", "delete", "allow", "2222/tcp"])
    if plan["panel_version"] == 4 and plan["panel_ip"]:
        cmds.append(
            ["ufw", "allow", "from", plan["panel_ip"], "to", "any", "port", "2222", "proto", "tcp", "comment", "Remnawave panel only"]
        )
    return cmds


def apply_sim(base: Path, plan: dict) -> None:
    if env_flag("REMNA_SIM_FAIL_SWAP"):
        raise RuntimeError("atomic swap failed")
    state = load_state(base)
    if plan["backend"] == "nftables":
        reason = nft_activation_block(state, True)
        if reason:
            raise RuntimeError(reason)
    new = copy.deepcopy(state)
    cmds = build_commands(plan, retire_nft=True, retire_iptables=True)
    cmds.extend(ufw_commands(plan, state.get("ufw_active", False), state.get("ufw_rules", [])))
    new["last_commands"] = [" ".join(c) for c in cmds]
    if plan["backend"] == "iptables":
        new["sets"] = {name: list(entries) for name, entries in plan["sets"].items()}
        new["chains"] = {CHAIN: list(plan["ipv4_rules"])}
        new["chains6"] = {CHAIN6: list(plan["ipv6_rules"])}
        new["input"] = retarget(state.get("input", []), CHAIN)
        new["input6"] = retarget(state.get("input6", []), CHAIN6)
        new["nft_table"] = ""
        new["owned_backend"] = "iptables"
        if state.get("ufw_active"):
            rules = [r for r in state.get("ufw_rules", []) if not (r.startswith("2222/tcp") and "Anywhere" in r)]
            if plan["panel_version"] == 4 and plan["panel_ip"]:
                rules.append(f"2222/tcp ALLOW IN {plan['panel_ip']}")
            new["ufw_rules"] = rules
    else:
        new["nft_table"] = plan["nft"]
        new["owned_backend"] = "nftables"
        new["chains"] = {}
        new["chains6"] = {}
        new["sets"] = {}
        new["input"] = drop_jump(state.get("input", []), CHAIN)
        new["input6"] = drop_jump(state.get("input6", []), CHAIN6)
    save_state(base, new)
    promote_staging(base)
    write_stats(base, plan, collisions=plan.get("render_collisions", 0))


def execute_live(plan: dict, state_hint: dict) -> None:
    if plan["backend"] == "nftables":
        reason = nft_activation_block(state_hint, False)
        if reason:
            raise RuntimeError(reason)
    cmds = build_commands(plan, retire_nft=True, retire_iptables=plan["backend"] == "nftables")
    restore = plan.get("ipset_restore", "")
    for cmd in cmds:
        if cmd[:2] == ["ipset", "restore"]:
            subprocess.run(cmd, input=restore.encode(), check=True)
            continue
        if cmd[:2] == ["nft", "-f"]:
            subprocess.run(cmd, input=plan.get("nft_payload", "").encode(), check=True)
            continue
        if cmd[:3] == ["iptables", "-N", CHAIN] or cmd[:3] == ["ip6tables", "-N", CHAIN6]:
            subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            continue
        if cmd[:3] in (["iptables", "-D", "INPUT"], ["ip6tables", "-D", "INPUT"]) or cmd[:2] == ["ipset", "destroy"] or cmd[:3] == ["nft", "delete", "table"]:
            subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            continue
        subprocess.run(cmd, check=True)
    if plan["backend"] == "iptables":
        while subprocess.run(["iptables", "-C", "INPUT", "-j", CHAIN], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            subprocess.run(["iptables", "-D", "INPUT", "-j", CHAIN], check=True)
        subprocess.run(["iptables", "-I", "INPUT", "1", "-j", CHAIN], check=True)
        while subprocess.run(["ip6tables", "-C", "INPUT", "-j", CHAIN6], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            subprocess.run(["ip6tables", "-D", "INPUT", "-j", CHAIN6], check=False)
        subprocess.run(["ip6tables", "-I", "INPUT", "1", "-j", CHAIN6], check=True)
        if ufw_active_live() and plan["panel_version"] == 4 and plan["panel_ip"]:
            status = subprocess.run(["ufw", "status"], text=True, capture_output=True)
            for line in (status.stdout or "").splitlines():
                if line.startswith("2222/tcp") and "Anywhere" in line:
                    subprocess.run(["ufw", "--force", "delete", "allow", "2222/tcp"], check=False)
            subprocess.run(
                ["ufw", "allow", "from", plan["panel_ip"], "to", "any", "port", "2222", "proto", "tcp", "comment", "Remnawave panel only"],
                check=False,
            )


def promote_staging(base: Path) -> None:
    staging = base / "staging"
    if not staging.exists():
        return
    data = base / "data"
    lkg = data / "lkg"
    data.mkdir(parents=True, exist_ok=True)
    lkg.mkdir(parents=True, exist_ok=True)
    for path in staging.glob("*.txt"):
        target = data / path.name
        target.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
        os.chmod(target, 0o600)
        (lkg / path.name).write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
        os.chmod(lkg / path.name, 0o600)
    for path in list(staging.glob("*")):
        path.unlink()


def discard_staging(base: Path) -> None:
    staging = base / "staging"
    if not staging.exists():
        return
    for path in staging.glob("*"):
        path.unlink()


def write_stats(base: Path, plan: dict, collisions: int) -> None:
    data = base / "data"
    data.mkdir(parents=True, exist_ok=True)
    prev = {}
    path = data / "stats.json"
    if path.exists():
        prev = json.loads(path.read_text(encoding="utf-8"))
    state = load_state(base) if env_flag("REMNA_SECURITY_SIM") else {}
    counters = state.get("counters") or prev.get("counters") or {
        "node_api": 0, "tspu": 0, "gov": 0, "deny": 0, "geo_default": 0, "scanners": 0
    }
    stats = {
        "schema": "remna-security.stats.v1",
        "backend": plan["backend"],
        "ruleset_hash": plan["ruleset_hash"],
        "ruleset_health": ruleset_health(base, plan),
        "render_collisions": collisions,
        "counters": counters,
        "ipv6_dynamic_lists": False,
        "last_apply_unix": int(time.time()),
    }
    path.write_text(json.dumps(stats, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def ruleset_health(base: Path, plan: dict | None = None) -> str:
    if env_flag("REMNA_SECURITY_SIM"):
        state = load_state(base)
        backend = (plan or {}).get("backend") or load_settings(base).get("BACKEND", "iptables")
        if backend == "nftables":
            table = state.get("nft_table") or ""
            if "dport 2222 drop" in table or "tcp dport 2222 drop" in table:
                return "ok" if node_api_protected(base) else "degraded"
            return "absent"
        if CHAIN not in state.get("chains", {}):
            return "absent"
        return "ok" if node_api_protected(base) else "degraded"
    return "unknown"


def node_api_state(base: Path) -> str:
    cfg = load_settings(base)
    if not valid_ip(cfg.get("PANEL_IP", "")):
        return "unprotected"
    if not env_flag("REMNA_SECURITY_SIM"):
        return "unknown"
    state = load_state(base)
    backend = cfg.get("BACKEND", "iptables")
    if backend == "nftables":
        table = state.get("nft_table") or ""
        if "tcp dport 2222 drop" not in table:
            return "unprotected"
        if panel_version(cfg) == 4 and f"ip saddr {cfg['PANEL_IP']}" not in table:
            return "broken"
        if panel_version(cfg) == 6 and f"ip6 saddr {cfg['PANEL_IP']}" not in table:
            return "broken"
        return "protected"
    rules = state.get("chains", {}).get(CHAIN, [])
    joined = "\n".join(rules)
    if f"-j {CHAIN}" not in "\n".join(state.get("input", [])):
        # exact jump check
        if not any(is_jump(r, CHAIN) for r in state.get("input", [])):
            return "unprotected"
    if "--dport 2222" not in joined or "-j DROP" not in joined:
        return "unprotected"
    if panel_version(cfg) == 4:
        accept = f"-A {CHAIN} -p tcp -s {cfg['PANEL_IP']} --dport 2222 -j ACCEPT"
        if accept not in rules:
            return "broken"
        if rules.index(accept) > next(i for i, r in enumerate(rules) if "--dport 2222" in r and "-j DROP" in r):
            return "broken"
    if panel_version(cfg) == 6:
        rules6 = state.get("chains6", {}).get(CHAIN6, [])
        accept6 = f"-A {CHAIN6} -p tcp -s {cfg['PANEL_IP']} --dport 2222 -j ACCEPT"
        if accept6 not in rules6:
            return "broken"
    return "protected"


def node_api_protected(base: Path) -> bool:
    return node_api_state(base) == "protected"


def count_entries(base: Path, filename: str) -> int:
    return len(read_lines(base / "data" / filename))


def source_status(base: Path, cfg: dict) -> dict:
    def one(key: str, enabled: bool, filename: str, mode: str) -> dict:
        return {
            "enabled": enabled,
            "entries": count_entries(base, filename),
            "mode": mode,
            "family": "ipv4",
            "dynamic_ipv6": False,
        }
    return {
        "tspu": one("tspu", cfg.get("ENABLE_TSPU") == "1", "tspu.txt", "pinned"),
        "gov": one("gov", cfg.get("ENABLE_GOV") == "1", "gov.txt", "pinned"),
        "geoip": one("geoip", cfg.get("ENABLE_GEOIP") == "1", "countries.txt", "pinned"),
        "scanners": one("scanners", cfg.get("ENABLE_SCANNERS") == "1", "scanners.txt", "fast"),
    }


def active_source_count(sources: dict) -> int:
    return sum(1 for item in sources.values() if item["enabled"] and item["entries"] > 0)


def detect_backend(base: Path) -> str:
    if env_flag("REMNA_SECURITY_SIM"):
        return load_state(base).get("detected", "iptables-nft")
    if env_flag("REMNA_SECURITY_FORBID_LIVE"):
        return "unknown"
    ipt = shutil.which("iptables")
    nft = shutil.which("nft")
    if ipt:
        try:
            out = subprocess.check_output([ipt, "--version"], text=True, stderr=subprocess.STDOUT)
        except Exception:
            out = ""
        if "nf_tables" in out:
            return "iptables-nft"
        if "legacy" in out:
            return "iptables-legacy"
        return "iptables-legacy"
    if nft:
        return "nft-native"
    return "unknown"


def docker_present(base: Path) -> bool:
    if env_flag("REMNA_SECURITY_SIM"):
        return bool(load_state(base).get("docker_chains"))
    if env_flag("REMNA_SECURITY_FORBID_LIVE"):
        return False
    ipt = shutil.which("iptables")
    if not ipt:
        return False
    proc = subprocess.run([ipt, "-S"], text=True, capture_output=True)
    text = proc.stdout or ""
    return "DOCKER" in text


def ufw_active_live() -> bool:
    if shutil.which("ufw") is None:
        return False
    proc = subprocess.run(["ufw", "status"], text=True, capture_output=True)
    return "Status: active" in (proc.stdout or "")


def emit_status(base: Path) -> dict:
    cfg = load_settings(base)
    sources = source_status(base, cfg)
    stats = {}
    stats_path = base / "data" / "stats.json"
    if stats_path.exists():
        stats = json.loads(stats_path.read_text(encoding="utf-8"))
    recent = []
    recent_path = base / "data" / "recent.json"
    if recent_path.exists():
        recent = json.loads(recent_path.read_text(encoding="utf-8"))
    last_error = ""
    last_ok = None
    last_unix = None
    update_path = base / "data" / "last-update.json"
    if update_path.exists():
        upd = json.loads(update_path.read_text(encoding="utf-8"))
        last_ok = upd.get("ok")
        last_error = upd.get("error") or ""
        last_unix = upd.get("unix")
    detected = detect_backend(base)
    configured = cfg.get("BACKEND", "iptables")
    health = stats.get("ruleset_health") or ruleset_health(base)
    api = node_api_state(base)
    return {
        "schema": SCHEMA_STATUS,
        "ok": api == "protected" and health == "ok",
        "backend": configured,
        "backend_implementation": detected,
        "panel_ip": cfg.get("PANEL_IP", ""),
        "node_api_2222": api,
        "filter_ports": ports_of(cfg) if valid_ports(cfg) else [],
        "ipv6": {
            "dynamic_lists": False,
            "node_api": "panel-allow-and-drop" if api == "protected" else api,
            "note": "Pinned TSPU, GOV, GeoIP and scanner feeds in this module are IPv4. IPv6 management protection is the owned REMNA_GUARD6 or nftables ip6 dport 2222 drop. Dynamic IPv6 blocklists are not claimed.",
        },
        "sources": sources,
        "active_source_count": active_source_count(sources),
        "last_update": {"unix": last_unix, "ok": last_ok, "error": last_error},
        "counters": stats.get("counters") or {"node_api": 0, "tspu": 0, "gov": 0, "deny": 0, "geo_default": 0, "scanners": 0},
        "recent_events": recent[-20:],
        "ruleset_health": health,
        "ruleset_hash": stats.get("ruleset_hash", ""),
        "config_dir": str(base),
        "log_drops": cfg.get("LOG_DROPS") == "1",
        "ipv6_manual_enforced": configured == "nftables",
    }


def emit_preflight(base: Path, target: str | None = None) -> dict:
    cfg = load_settings(base)
    blockers = []
    warnings = []
    if not valid_ip(cfg.get("PANEL_IP", "")):
        blockers.append("panel_ip_missing_or_invalid")
    if not valid_ports(cfg):
        blockers.append("filter_ports_invalid")
    state = load_state(base) if env_flag("REMNA_SECURITY_SIM") else {
        "ufw_active": ufw_active_live() if not env_flag("REMNA_SECURITY_FORBID_LIVE") else False,
        "docker_chains": ["DOCKER"] if docker_present(base) else [],
        "nft_available": shutil.which("nft") is not None,
    }
    configured = target or cfg.get("BACKEND", "iptables")
    nft_reason = ""
    if configured == "nftables":
        nft_reason = nft_activation_block(state, env_flag("REMNA_SECURITY_SIM"))
        if nft_reason:
            blockers.append(nft_reason)
    if state.get("docker_chains"):
        warnings.append("docker_chains_present_owned_resources_only")
    if state.get("ufw_active"):
        warnings.append("ufw_active_owned_resources_only")
    warnings.append("ipv6_dynamic_lists_unsupported")
    if cfg.get("ENABLE_SCANNERS") == "1" and not cfg.get("SCANNER_URL"):
        warnings.append("scanners_enabled_without_url")
    return {
        "schema": SCHEMA_PREFLIGHT,
        "ok": not blockers,
        "blockers": blockers,
        "warnings": warnings,
        "detected_backend": detect_backend(base),
        "configured_backend": cfg.get("BACKEND", "iptables"),
        "target_backend": configured,
        "nft_activation": "refused" if nft_reason else "allowed",
        "nft_refuse_reason": nft_reason,
        "ufw_active": bool(state.get("ufw_active")),
        "docker_present": bool(state.get("docker_chains")),
        "panel_ip_valid": valid_ip(cfg.get("PANEL_IP", "")),
        "owns_only": True,
        "ipv6_dynamic_lists": False,
    }


def add_event(base: Path, kind: str, message: str) -> None:
    path = base / "data" / "recent.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    events = []
    if path.exists():
        events = json.loads(path.read_text(encoding="utf-8"))
    now = int(time.time())
    if events:
        last = events[-1]
        if last.get("kind") == kind and last.get("message") == message and now - int(last.get("unix", 0)) < 60:
            return
    events.append({"unix": now, "kind": kind, "message": message})
    path.write_text(json.dumps(events[-20:], indent=2) + "\n", encoding="utf-8")


def accept_source(base: Path, source_id: str, raw_path: Path) -> dict:
    meta = SOURCE_META[source_id]
    cfg = load_settings(base)
    previous_name = "countries.txt" if source_id == "geoip" else f"{source_id}.txt"
    previous = read_lines(base / "data" / previous_name)
    lkg = read_lines(base / "data" / "lkg" / previous_name)
    baseline = lkg or previous
    raw = raw_path.read_bytes()
    report = validate_feed(
        raw,
        meta["mode"],
        meta["family"],
        baseline,
        cfg.get("PANEL_IP", ""),
        read_lines(base / "data" / "allow.txt"),
        meta["min_absolute"],
    )
    report["id"] = source_id
    report["kept_lkg"] = not report["ok"]
    staging = base / "staging"
    staging.mkdir(parents=True, exist_ok=True)
    (staging / f"{source_id}.report.json").write_text(json.dumps({k: v for k, v in report.items() if k != "entries"}, indent=2) + "\n", encoding="utf-8")
    if report["ok"]:
        name = "countries.txt" if source_id == "geoip" else f"{source_id}.txt"
        target = staging / name
        target.write_text("".join(f"{e}\n" for e in report["entries"]), encoding="utf-8")
        os.chmod(target, 0o600)
    else:
        add_event(base, "source_error", f"{source_id}:{report['reason']}")
    return report


def finalize_update(base: Path, results: list[dict]) -> dict:
    failed = [item for item in results if not item.get("ok")]
    doc = {
        "schema": SCHEMA_UPDATE,
        "ok": not failed,
        "unix": int(time.time()),
        "error": ",".join(f"{item['id']}:{item['reason']}" for item in failed),
        "changed": any(item.get("ok") for item in results),
        "sources": [
            {
                "id": item["id"],
                "ok": item["ok"],
                "error": "" if item["ok"] else item["reason"],
                "entries": item.get("accepted", 0),
                "kept_lkg": item.get("kept_lkg", not item["ok"]),
                "panel_collisions": item.get("panel_collisions", 0),
                "whitelist_collisions": item.get("whitelist_collisions", 0),
            }
            for item in results
        ],
    }
    path = base / "data" / "last-update.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    return doc


def manual_check(value: str, kind: str, panel: str) -> str:
    try:
        net = parse_network(value if "/" in value else value + "/32")
    except Exception:
        return "malformed"
    if net.version == 4 and net.prefixlen < 8:
        return "broad"
    if kind == "deny" and panel:
        try:
            panel_net = parse_network(panel if "/" in panel else panel + "/32")
        except Exception:
            panel_net = None
        if panel_net and net.overlaps(panel_net):
            return "panel_overlap"
    return "ok"


def update_list_file(base: Path, filename: str, value: str, remove: bool) -> None:
    path = base / "data" / filename
    path.parent.mkdir(parents=True, exist_ok=True)
    current = read_lines(path)
    canon = str(parse_network(value if "/" in value else value + "/32"))
    if remove:
        current = [item for item in current if item != canon and item != value]
    else:
        if canon not in current:
            current.append(canon)
    path.write_text("".join(f"{item}\n" for item in sorted(current)) + ("" if current else ""), encoding="utf-8")
    os.chmod(path, 0o600)


def unit_texts(entrypoint: str) -> dict[str, str]:
    service = f"""[Unit]
Description=RemnaNode Security owned firewall restore
After=network-pre.target
Before=docker.service

[Service]
Type=oneshot
ExecStart={entrypoint} apply
RemainAfterExit=yes
LogRateLimitIntervalSec=30s
LogRateLimitBurst=20

[Install]
WantedBy=multi-user.target
"""
    update = f"""[Unit]
Description=RemnaNode Security feed update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart={entrypoint} update
LogRateLimitIntervalSec=30s
LogRateLimitBurst=20
"""
    timer = """[Unit]
Description=Weekly RemnaNode Security pinned-feed check

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true
RandomizedDelaySec=15m
Unit=remna-protection-update.service

[Install]
WantedBy=timers.target
"""
    return {
        "remna-protection.service": service,
        "remna-protection-update.service": update,
        "remna-protection-update.timer": timer,
    }


LOGROTATE = """/var/log/remna-protection/*.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    copytruncate
    su root root
}
"""


def write_units(dest: Path, entrypoint: str, base: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    texts = unit_texts(entrypoint)
    for name, body in texts.items():
        path = dest / name
        path.write_text(body, encoding="utf-8")
    if env_flag("REMNA_SECURITY_SIM"):
        state = load_state(base)
        state["units"] = {name: "enabled" for name in texts}
        save_state(base, state)


def audit_state(base: Path) -> dict:
    state = load_state(base) if env_flag("REMNA_SECURITY_SIM") else {}
    unsafe = []
    for cmd in state.get("last_commands") or []:
        parts = cmd.split()
        if len(parts) >= 3 and parts[0] in {"iptables", "ip6tables"} and parts[1] == "-F" and parts[2] in {"INPUT", "FORWARD", "OUTPUT", "DOCKER", "DOCKER-USER"}:
            unsafe.append(cmd)
        if parts[:2] == ["ufw", "reset"] or (parts[:1] == ["ufw"] and "reset" in parts):
            unsafe.append(cmd)
        if parts[:3] == ["nft", "flush", "ruleset"]:
            unsafe.append(cmd)
    return {
        "ssh_accept": any("--dport 22" in rule and "ACCEPT" in rule for rule in state.get("input", [])),
        "docker_user_jump": any(is_jump(rule, "DOCKER-USER") for rule in state.get("input", [])),
        "guard_jumps": sum(1 for rule in state.get("input", []) if is_jump(rule, CHAIN)),
        "guard6_jumps": sum(1 for rule in state.get("input6", []) if is_jump(rule, CHAIN6)),
        "wide_ufw_2222": any(rule.startswith("2222/tcp") and "Anywhere" in rule for rule in state.get("ufw_rules", [])),
        "ufw_22": any(rule.startswith("22/tcp") for rule in state.get("ufw_rules", [])),
        "docker_chains": list(state.get("docker_chains") or []),
        "unsafe_commands": unsafe,
        "owned_backend": state.get("owned_backend", ""),
        "nft_active": bool(state.get("nft_table")),
    }


def uninstall_live() -> None:
    """Remove only Remna-owned chains, sets and the owned nft table."""
    for bin_name, chain in (("iptables", CHAIN), ("ip6tables", CHAIN6)):
        if shutil.which(bin_name) is None:
            continue
        while subprocess.run([bin_name, "-C", "INPUT", "-j", chain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            subprocess.run([bin_name, "-D", "INPUT", "-j", chain], check=False)
        subprocess.run([bin_name, "-F", chain], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([bin_name, "-X", chain], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if shutil.which("ipset"):
        for name in (SET_TSPU, SET_GOV, SET_ALLOW, SET_DENY, SET_COUNTRY, SET_SCANNERS):
            subprocess.run(["ipset", "destroy", name], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if shutil.which("nft"):
        subprocess.run(["nft", "delete", "table", NFT_FAMILY, NFT_TABLE], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def uninstall_sim(base: Path) -> None:
    state = load_state(base)
    state["input"] = drop_jump(state.get("input", []), CHAIN)
    state["input6"] = drop_jump(state.get("input6", []), CHAIN6)
    state["chains"] = {}
    state["chains6"] = {}
    state["sets"] = {}
    state["nft_table"] = ""
    state["owned_backend"] = ""
    state["units"] = {}
    state["last_commands"] = [
        "iptables -D INPUT -j REMNA_GUARD",
        "iptables -F REMNA_GUARD",
        "iptables -X REMNA_GUARD",
        "ip6tables -D INPUT -j REMNA_GUARD6",
        "ip6tables -F REMNA_GUARD6",
        "ip6tables -X REMNA_GUARD6",
        "nft delete table inet remna_security",
    ]
    save_state(base, state)


def selftest_doc(base: Path, steps: list[dict]) -> dict:
    return {
        "schema": SCHEMA_SELFTEST,
        "ok": all(step["ok"] for step in steps),
        "steps": steps,
        "node_api_2222": node_api_state(base),
        "backend": load_settings(base).get("BACKEND", "iptables"),
        "ipv6_dynamic_lists": False,
    }


def dump_json(doc: dict) -> None:
    sys.stdout.write(json.dumps(doc, indent=2, sort_keys=True) + "\n")


def cmd_validate(args: argparse.Namespace) -> int:
    raw = Path(args.raw).read_bytes()
    previous = read_lines(Path(args.previous)) if args.previous else []
    allow = read_lines(Path(args.allow)) if args.allow else []
    report = validate_feed(raw, args.mode, args.family, previous, args.panel or "", allow, args.min_absolute)
    if args.report:
        Path(args.report).write_text(json.dumps({k: v for k, v in report.items() if k != "entries"}, indent=2) + "\n", encoding="utf-8")
    if report["ok"] and args.out:
        Path(args.out).write_text("".join(f"{e}\n" for e in report["entries"]), encoding="utf-8")
    if args.print_json:
        dump_json({k: v for k, v in report.items() if k != "entries" or args.show_entries})
    return 0 if report["ok"] else 1


def cmd_apply(args: argparse.Namespace) -> int:
    base = Path(args.base)
    sim = env_flag("REMNA_SECURITY_SIM")
    forbid = env_flag("REMNA_SECURITY_FORBID_LIVE")
    cfg = load_settings(base)
    if not valid_ip(cfg.get("PANEL_IP", "")) or not valid_ports(cfg):
        print("refusing to change firewall: PANEL_IP or FILTER_PORTS is invalid", file=sys.stderr)
        return 1
    plan = build_plan(base)
    if args.print_commands or args.print_plan:
        cmds = build_commands(plan, True, True)
        if args.print_plan:
            public = {k: v for k, v in plan.items() if k != "ipset_restore"}
            public["commands"] = [" ".join(c) for c in cmds]
            dump_json(public)
        else:
            dump_json([" ".join(c) for c in cmds])
        if args.print_commands and not args.commit:
            return 0
    if not sim:
        if forbid:
            print("live firewall changes are forbidden in this environment", file=sys.stderr)
            return 2
        try:
            hint = {
                "ufw_active": ufw_active_live(),
                "docker_chains": ["DOCKER"] if docker_present(base) else [],
            }
            execute_live(plan, hint)
            promote_staging(base)
            write_stats(base, plan, plan.get("render_collisions", 0))
        except Exception as exc:
            discard_staging(base)
            print(str(exc), file=sys.stderr)
            return 1
        return 0
    try:
        apply_sim(base, plan)
    except Exception as exc:
        discard_staging(base)
        print(str(exc), file=sys.stderr)
        return 1
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="remna_sec")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("validate")
    p.add_argument("--raw", required=True)
    p.add_argument("--mode", choices=["plain", "gov"], required=True)
    p.add_argument("--family", default="ipv4")
    p.add_argument("--previous")
    p.add_argument("--allow")
    p.add_argument("--panel", default="")
    p.add_argument("--min-absolute", type=int, default=1)
    p.add_argument("--out")
    p.add_argument("--report")
    p.add_argument("--print-json", action="store_true")
    p.add_argument("--show-entries", action="store_true")

    p = sub.add_parser("blob")
    p.add_argument("--file", required=True)

    p = sub.add_parser("apply")
    p.add_argument("--base", required=True)
    p.add_argument("--print-commands", action="store_true")
    p.add_argument("--print-plan", action="store_true")
    p.add_argument("--commit", action="store_true")

    p = sub.add_parser("emit")
    p.add_argument("kind", choices=["status", "preflight", "update", "selftest"])
    p.add_argument("--base", required=True)
    p.add_argument("--target")
    p.add_argument("--steps")

    p = sub.add_parser("accept-source")
    p.add_argument("--base", required=True)
    p.add_argument("--id", required=True, choices=sorted(SOURCE_META))
    p.add_argument("--raw", required=True)

    p = sub.add_parser("finalize-update")
    p.add_argument("--base", required=True)
    p.add_argument("--results", required=True)

    p = sub.add_parser("event")
    p.add_argument("--base", required=True)
    p.add_argument("--kind", required=True)
    p.add_argument("--message", required=True)

    p = sub.add_parser("sim-seed")
    p.add_argument("--base", required=True)
    p.add_argument("--profile", required=True, choices=["docker", "isolated", "ufw"])

    p = sub.add_parser("sim-drop-hook")
    p.add_argument("--base", required=True)

    p = sub.add_parser("manual")
    p.add_argument("--base", required=True)
    p.add_argument("--file", required=True)
    p.add_argument("--value", required=True)
    p.add_argument("--remove", action="store_true")

    p = sub.add_parser("write-units")
    p.add_argument("--base", required=True)
    p.add_argument("--dest", required=True)
    p.add_argument("--entrypoint", required=True)

    p = sub.add_parser("write-logrotate")
    p.add_argument("--dest", required=True)

    p = sub.add_parser("uninstall")
    p.add_argument("--base", required=True)

    p = sub.add_parser("detect")
    p.add_argument("--base", required=True)

    p = sub.add_parser("audit")
    p.add_argument("--base", required=True)

    args = parser.parse_args(argv)
    if args.cmd == "validate":
        return cmd_validate(args)
    if args.cmd == "blob":
        data = Path(args.file).read_bytes()
        sys.stdout.write(git_blob_sha1(data) + "\n")
        return 0
    if args.cmd == "apply":
        return cmd_apply(args)
    if args.cmd == "emit":
        base = Path(args.base)
        if args.kind == "status":
            dump_json(emit_status(base))
        elif args.kind == "preflight":
            dump_json(emit_preflight(base, args.target))
        elif args.kind == "update":
            path = base / "data" / "last-update.json"
            if not path.exists():
                dump_json({"schema": SCHEMA_UPDATE, "ok": False, "error": "no_update", "sources": [], "changed": False, "unix": None})
            else:
                dump_json(json.loads(path.read_text(encoding="utf-8")))
        else:
            steps = json.loads(Path(args.steps).read_text(encoding="utf-8")) if args.steps else []
            dump_json(selftest_doc(base, steps))
        return 0
    if args.cmd == "accept-source":
        report = accept_source(Path(args.base), args.id, Path(args.raw))
        dump_json({k: v for k, v in report.items() if k != "entries"})
        return 0 if report["ok"] else 1
    if args.cmd == "finalize-update":
        results = json.loads(Path(args.results).read_text(encoding="utf-8"))
        dump_json(finalize_update(Path(args.base), results))
        return 0
    if args.cmd == "event":
        add_event(Path(args.base), args.kind, args.message)
        return 0
    if args.cmd == "sim-seed":
        Path(args.base).mkdir(parents=True, exist_ok=True)
        seed_state(Path(args.base), args.profile)
        return 0
    if args.cmd == "sim-drop-hook":
        base = Path(args.base)
        state = load_state(base)
        state["input"] = drop_jump(state.get("input", []), CHAIN)
        state["input6"] = drop_jump(state.get("input6", []), CHAIN6)
        save_state(base, state)
        return 0
    if args.cmd == "manual":
        base = Path(args.base)
        cfg = load_settings(base)
        kind = "deny" if args.file == "deny.txt" else "allow"
        if not args.remove:
            reason = manual_check(args.value, kind, cfg.get("PANEL_IP", ""))
            if reason != "ok":
                print(reason, file=sys.stderr)
                return 1
        update_list_file(base, args.file, args.value, args.remove)
        return 0
    if args.cmd == "write-units":
        write_units(Path(args.dest), args.entrypoint, Path(args.base))
        return 0
    if args.cmd == "write-logrotate":
        dest = Path(args.dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(LOGROTATE, encoding="utf-8")
        return 0
    if args.cmd == "uninstall":
        if env_flag("REMNA_SECURITY_SIM"):
            uninstall_sim(Path(args.base))
            return 0
        if env_flag("REMNA_SECURITY_FORBID_LIVE"):
            print("live firewall changes are forbidden in this environment", file=sys.stderr)
            return 2
        uninstall_live()
        return 0
    if args.cmd == "detect":
        sys.stdout.write(detect_backend(Path(args.base)) + "\n")
        return 0
    if args.cmd == "audit":
        dump_json(audit_state(Path(args.base)))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
