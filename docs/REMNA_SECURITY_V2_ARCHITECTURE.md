# RemnaNode Security V2 architecture

Reviewed source: `coord/remna-security-v2-architecture` @ `6876cc4902187f4ef610ad96c85fc21e356d937d`.

Independent gate: APPROVE / ALLOW_ADVISORY. This tree is the first integrated candidate on remna-node-scripts. It is an evolution of the existing protection and transport tooling. It is not a second product, not a second orchestrator, and not a second firewall owner.

No production activation is in scope. WARP, QUIC noise, automatic policy, scanner fast feeds, nftables cutover, and live routing stay off.

## Three planes

Policy may name a plane. It does not merge ownership.

| Plane | Owns | Does not own |
| --- | --- | --- |
| Inbound protection | Current Remna Security firewall: scanner/TSPU/GOV, TCP/2222, allow/deny, last-known-good, rollback, owned iptables/ipset or the refused nftables table | WARP credentials, client transport profiles, egress routes |
| Client transport | XHTTP/REALITY, RAW/REALITY, Hysteria2, combined, self-steal | Inbound sets, egress backends |
| Egress | direct, and later WARP or WARP with QUIC noise | Inbound drops, Hysteria2 as a backend |

WARP is not an inbound protection mode. Hysteria2 is not an egress backend. Each plane has its own generation, status, and rollback. A shared transaction id may be recorded across planes; rollback of one plane must not delete another plane's state.

Lock order when more than one plane is touched:

1. transaction lock `v2/locks/transaction.lock`
2. layer locks in the fixed order inbound, then transport, then egress

A caller that holds the egress lock must not take the inbound lock. Cleanup of old generations runs only after that layer's current pointer is committed, and only while the transaction lock and that layer lock are still held.

## What stays authoritative

Current remna-node-scripts behavior stays in place unless this candidate adds an explicit offline contract:

- XHTTP/REALITY, RAW/REALITY, Hysteria2, and the combined profile, including runtime validation already in the transport manager
- Pinned TSPU/GOV/GeoIP trust, atomic ipset swap, last-known-good, rollback
- JSON API, simulator, and owned-only firewall changes
- No global `iptables -F INPUT`, no `ufw reset`, no `nft flush ruleset`

NEXT installers are not retargeted. The pinned source bundle is not edited.

## Inbound plane

The existing entrypoint remains `protection-manager.sh` -> `security/remna-security.sh` -> `security/remna_sec.py`.

Kept: `REMNA_GUARD` / `REMNA_GUARD6`, owned `REMNA_*` sets, panel-first TCP/2222, manual allow/deny, pinned feeds, prefix shorter than /8 rejected as a whole, panel and allow subtraction, simulator, `REMNA_SECURITY_FORBID_LIVE=1`.

V2 adds a catalog of scanner categories (TSPU, GOV, Censys, Shodan, Shadowserver, Rapid7, ZoomEye, LeakIX, ONYPHE, FOFA, Quake). Only TSPU and GOV are default-enabled, and only with immutable provenance and a checksum. Mutable fast feeds are refused in this candidate. Anything that is admitted still goes through `validate_feed` (validation, last-known-good, panel/allow subtraction).

nftables remains a detected backend that preflight can refuse. `FEATURE_NFTABLES_CUTOVER` cannot become effective here.

## Transport plane

Existing profile files and semantics stay where they are. V2 adds a decoy contract under the transport layer:

- stable per-node seed (`HMAC-SHA256(node key, node id)`)
- status, rotate, and rollback of a generation counter
- runtime trackers and external assets forced off

The HTML/self-steal renderer is the next implementation step. It must not write inbound firewall rules.

A Remnawave node plugin, if added later, is optional and application-aware. `authoritative_ingress: true` is rejected. Host firewall ownership stays with the inbound plane.

## Egress plane

Code lives under `security/v2/`. It can build and test data offline. It does not change live routes.

- X25519 identity, local root-only secret files (mode `0600`)
- Registration client with failure classes: `network`, `ambiguous_timeout`, `non_json`, `waf`, `http_error`
- Registration is not retried after an ambiguous timeout. A connect failure before the request is sent may be retried once. Idempotent enable/update may retry a bounded number of times, including an ambiguous timeout.
- Lifecycle records creation, last success, and rotation generation. `verified_expiry` is set only when the provider body actually contains an expiry field. Undocumented Cloudflare deletion or expiry behavior is not invented.
- A new generation replaces last-known-good credentials only after selftest. Ambiguous cleanup sets `orphan_risk` and does not claim deletion.
- No Vercel, Upstash, public frontend, public subscription, or external secret store.
- Status redacts private key, bearer token, raw authorization, and raw provider account id.

Endpoint pool, strongest trust first: configured, last-known-good, registration, discovered. There is no single hardcoded endpoint. Discovery inserts candidates only. A discovered endpoint becomes selectable after healthcheck. Health is an injected end-to-end classification through the WARP path, not a DNS lookup. Two probe targets are required when the catalog has them. Rotation and jitter are deterministic from a seed. `probe_target` failure is not a WARP-path failure. Promotion needs two successes. Three consecutive WARP-path failures start cooldown. A new boot id marks every record unknown until it is validated again.

QUIC noise is an independent implementation of a QUIC v1 Initial (RFC 9000/9001) plus the reviewed outbound shape: wireguard `streamSettings.sockopt.dialerProxy` points at a dedicated freedom outbound whose noises are one `rand` range and one base64 Initial. Profile structure is versioned and hashed. Packet bytes change per generation. The code does not claim that the noise is undetectable or that it bypasses a network.

## Detector and policy

Detector facts carry `observed_at`, `source`, `severity`, `confidence`, `ttl_seconds`, `dedup_key`, and `occurrence_count`. Default aggregation window is 60 seconds. Identical keys inside the window increment the count. Fact TTL and a 24 hour absolute retention both apply. The queue is bounded and overflow is an event. Facts do not change firewall, transport, or egress state.

`policy-evaluate` is pure. It returns current state, recommended state, triggering facts, target layers, proposed change, risk, `approval_required`, and a rollback id. `policy-apply` checks `FEATURE_AUTO_POLICY` and then refuses. Configuring the flag to 1 does not enable mutation and does not rewrite the file into a "fixed" shape.

## Feature flags

One file: `<base>/v2/policy/features.json`, directory `0700`, file `0600`. Defaults are all zero:

- `FEATURE_EGRESS_WARP`
- `FEATURE_WARP_QUIC_NOISE`
- `FEATURE_AUTO_POLICY`
- `FEATURE_SCANNER_FAST`
- `FEATURE_NFTABLES_CUTOVER`
- `FEATURE_DECOY_RUNTIME`
- `FEATURE_NODE_PLUGIN`

`FEATURE_AUTO_POLICY` is hard-off: effective value is always 0 in this candidate. QUIC noise without WARP fails validation and the effective QUIC bit stays 0. The stored configured values are left as written. `live_effect` is false. The CLI refuses an implicit base, refuses `/opt/ainoc`, and refuses `/opt/remna-protection` unless `REMNA_V2_ALLOW_NODE_BASE=1` (not used by tests or this task).

## Durability

Owned state is under `<base>/v2/`. A commit writes a temp file, fsyncs it, renames it, then fsyncs the parent directory when the platform allows that. `EINVAL` / `ENOTSUP` / `EOPNOTSUPP` are reported as `durability: degraded` and must not be described as fully crash-safe. Each layer keeps the current generation and five previous committed generations. A crash after the payload rename and before the pointer rename leaves the previous current pointer in place.

## Xray / rw-core

The activation sequence is representable and is not executed:

candidate temp file -> syntax/semantic validation -> real `rw-core`/`xray run -test` -> snapshot -> atomic rename -> detected reload or verified restart -> end-to-end verification -> rollback on failure.

`execute` is false. `activated` is false. An unknown reload method refuses the plan. `SIGHUP` is not assumed and is refused.

## Later phases (not this candidate)

- Phase C: runtime preflight and selftest on a non-production host
- Phase D: lab field matrix (at least three fixed broadband paths, at least two mobile paths when available, CGNAT, IPv4-only, dual-stack, constrained MTU/loss)
- Phase E: production, only as a separate human decision, and not proposed while a critical field failure is unexplained
