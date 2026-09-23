"""Endpoint pool. Discovery only creates candidates.

Trust order, strongest first: configured, last-known-good, registration, discovered.
A discovered endpoint cannot become active until healthcheck promotes it.
There is no single hardcoded endpoint invariant.
"""

from __future__ import annotations

import ipaddress
import re
from dataclasses import dataclass

from security.v2.contracts import ENDPOINT_ORIGINS, TRUST_RANK

_HOST = re.compile(r"^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$")


@dataclass(frozen=True)
class Endpoint:
    host: str
    port: int
    family: str
    origin: str

    def key(self) -> str:
        if self.family == "ipv6":
            return f"[{self.host}]:{self.port}"
        return f"{self.host}:{self.port}"


def parse_endpoint(text: str, origin: str) -> Endpoint:
    if origin not in ENDPOINT_ORIGINS:
        raise ValueError("origin")
    raw = text.strip()
    if not raw:
        raise ValueError("empty endpoint")
    host, port_text = _split_host_port(raw)
    try:
        port = int(port_text)
    except ValueError as exc:
        raise ValueError("port") from exc
    if not 1 <= port <= 65535:
        raise ValueError("port range")
    family = _family(host)
    return Endpoint(host=host, port=port, family=family, origin=origin)


def parse_registration_endpoint(endpoint: dict, origin: str = "registration") -> list[Endpoint]:
    found = []
    host = endpoint.get("host")
    port = int(endpoint.get("port") or 2408)
    if host:
        found.append(parse_endpoint(f"{_bracket(host)}:{port}" if ":" in host and not host.startswith("[") else f"{host}:{port}", origin))
    for key, family_origin in (("v4", origin), ("v6", origin)):
        value = endpoint.get(key)
        if value:
            token = value if ":" not in str(value) or key == "v4" else f"[{value}]"
            if key == "v6" and not str(value).startswith("["):
                token = f"[{value}]"
            found.append(parse_endpoint(f"{token}:{port}", origin))
    return found


def _bracket(host: str) -> str:
    if ":" in host and not host.startswith("["):
        return f"[{host}]"
    return host


def _split_host_port(raw: str) -> tuple[str, str]:
    if raw.startswith("["):
        end = raw.find("]")
        if end < 0 or len(raw) < end + 2 or raw[end + 1] != ":":
            raise ValueError("ipv6 endpoint")
        return raw[1:end], raw[end + 2 :]
    if raw.count(":") == 1:
        host, port = raw.rsplit(":", 1)
        return host, port
    if raw.count(":") > 1:
        raise ValueError("ipv6 endpoint requires brackets")
    raise ValueError("missing port")


def _family(host: str) -> str:
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        if not _HOST.match(host):
            raise ValueError("name")
        return "name"
    return "ipv6" if ip.version == 6 else "ipv4"


def select_active(endpoints: list[Endpoint], healthy: set[str]) -> Endpoint | None:
    """Pick the most trusted healthy endpoint. Discovered stays inactive until healthy."""
    ranked = sorted(endpoints, key=lambda item: (TRUST_RANK[item.origin], item.key()))
    for item in ranked:
        if item.origin == "discovered" and item.key() not in healthy:
            continue
        if item.key() not in healthy:
            continue
        return item
    return None
