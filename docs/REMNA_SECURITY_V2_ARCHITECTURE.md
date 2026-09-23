# RemnaNode Security V2 — integrated architecture roadmap

Status: architecture only. No production activation, no live firewall change, no WARP activation.

Base: `evgmahov-blip/remna-node-scripts@32ad1743c7b27b91cb6ad0997100b358917cde4a`.

Reference snapshots reviewed for this architecture:

- `eGamesAPI/remnawave-reverse-proxy@7b29ddbee076c30e85d4e9f7e9bdd30d2120f551`
- `Balbuto/RKN-Watcher@558fc11a0792892927785e162359585d51972a6a`
- `Flecksis/rkn-guard@391875ae3bf750bd4cf5ddd6d5aec7153ce17cc6`
- `SolverNA/warp-xray-generator@dcd99bcc9799c0d30f08eb166beeb5fb180a4964`

This document extends the current RemnaNode Security subsystem. It does not create a parallel product, daemon, orchestrator, public frontend, subscription service, or separate protection stack.

## 1. Design rule: keep three planes separate

The node has three independent planes. They may be combined by policy, but must not own each other's configuration.

### A. Inbound protection plane

Purpose: protect the node itself.

Owns:

- TCP/2222 panel-only policy;
- TSPU/GOV/scanner source sets;
- manual allow/deny;
- IPv4/IPv6 host firewall enforcement;
- counters, recent events, rollback, last-known-good;
- decoy/self-steal exposure policy;
- optional Remnawave ingress plugin integration.

It is implemented by the existing `protection-manager.sh` → `security/remna-security.sh` + `security/remna_sec.py` subsystem.

### B. Client transport plane

Purpose: how a client reaches the Remnawave node.

Owns:

- VLESS + REALITY + XHTTP;
- VLESS + REALITY + RAW;
- Hysteria2 + TLS/QUIC;
- combined TCP/443 XHTTP + UDP/443 Hysteria2;
- profile generation and runtime `rw-core/Xray run -test`;
- self-steal handoff compatibility.

The transport plane must not directly mutate host firewall sources or WARP credentials.

### C. Egress plane

Purpose: how traffic leaves the node after it has been accepted.

Initial backends:

- `direct`
- `warp`
- `warp_quic_noise`

Future backends may be added behind the same interface.

The egress plane must not be treated as inbound anti-scanner protection and must not redefine client transport.

## 2. Unified control flow

The V2 policy flow is:

```text
RKN-Watcher ideas / rkn-guard ideas / current Remna Security telemetry
+ eGames scanner intelligence
+ node diagnostics / transport health / endpoint health
        |
        v
     DETECTOR
        |
        v
   POLICY ENGINE
        |
        +--> inbound policy
        |      normal / hardened
        |
        +--> client transport preference
        |      XHTTP / RAW / Hysteria2 / alternate endpoint
        |
        +--> egress backend
               direct / WARP / WARP+QUIC-noise
```

No detector signal directly rewrites a live profile. The detector emits facts. The policy engine selects a declared mode. Activation remains a separate guarded operation.

## 3. What remains from the current security subsystem

The fresh main already contains the right foundation and remains authoritative:

- owned firewall objects only;
- explicit `PANEL_IP` safety for TCP/2222;
- pinned TSPU/GOV/GeoIP snapshots;
- CIDR sanitation;
- panel/allow subtraction from external block feeds;
- atomic set swap;
- last-known-good;
- rollback snapshots;
- JSON status/preflight/update/selftest contracts;
- simulator/offline tests;
- guarded nftables support;
- no global UFW/iptables/nft reset;
- scanner feed disabled by default;
- live-apply refusal for non-activation work.

V2 extends this model. It does not replace it.

## 4. RKN-Watcher and rkn-guard role in V2

Use them as sources of operational ideas, not as new products.

Keep:

- reviewed slow sources versus faster scanner intelligence;
- set-based matching;
- atomic replacement;
- last-known-good;
- whitelist/manual lists;
- port-scoped filtering;
- status counters;
- ban/unban style operator controls;
- systemd lifecycle;
- explicit IPv4/IPv6 truthfulness;
- integration tests.

Do not add:

- a second daemon;
- a second firewall owner;
- a new database just for bans;
- mutable upstream lists trusted without review;
- a web UI as a requirement.

## 5. eGames role in V2

Take selected capabilities, not the whole reverse-proxy stack.

### 5.1 Scanner intelligence

Import the idea of scanner categories/presets:

- TSPU / Skipa;
- GOV;
- Censys;
- Shodan;
- Shadowserver;
- Rapid7;
- ZoomEye;
- LeakIX;
- ONYPHE;
- FOFA;
- Quake;
- future reviewed classes.

All new feeds must still pass the Remna Security trust pipeline. Default-on feeds require immutable commit/checksum provenance. Fast mutable feeds stay feature-flagged and are never allowed to replace last-known-good on validation failure.

### 5.2 Decoy/self-steal engine

Take the useful ideas from eGames template randomization and improve them:

- several reviewed local/pinned template families;
- per-node persistent seed;
- stable per-node mutation, not regeneration on every restart;
- title/meta/comment/class/id mutation;
- optional safe local asset path/name mutation;
- favicon variation;
- sane 404/robots behavior;
- no external runtime analytics or tracking;
- explicit rotate + rollback;
- decoy fingerprint/status/selftest.

This remains a separate layer from the firewall and from egress.

### 5.3 Remnawave node plugin

Treat ingress/egress/torrent plugin capabilities as an optional application-aware layer.

The host firewall remains the authoritative host security boundary. Do not create two competing authoritative ingress filters.

## 6. WARP backend from warp-xray-generator

Do not fork or deploy its Vercel application.

Useful modules/ideas to reimplement locally:

1. local WARP account registration;
2. local credential lifecycle;
3. Xray WireGuard outbound builder;
4. `sockopt.dialerProxy` to a separate freedom outbound;
5. valid QUIC v1 Initial generation;
6. randomized Xray `freedom.noises`;
7. endpoint parsing and validation;
8. endpoint pool health and failover.

Not needed:

- Vercel;
- public frontend;
- public subscription links;
- Upstash/public temporary config storage;
- browser UI;
- server-side delivery of private WireGuard keys.

## 7. WARP registration backend

Provide a local-only module, conceptually:

```text
security/egress/
  warp-account.*
  warp-endpoints.*
  warp-noise.*
  warp-config.*
```

Responsibilities:

- generate X25519 keypairs locally;
- register WARP locally;
- enable WARP locally;
- store account id/token/private key only on the node;
- retain enough account identity for lifecycle cleanup/rotation;
- distinguish network failure, non-JSON/WAF response, and HTTP error;
- do not blindly retry non-idempotent registration requests;
- allow safe retry of idempotent WARP-enable/update operations;
- expose machine-readable status without printing private material.

Secrets must live in a root-only state directory, for example:

```text
/opt/remna-protection/egress/warp/
  account.json        0600
  private.key         0600
  endpoints.json      0644 or 0600
  state.json
```

Exact paths may change during implementation, but secrets must never be written to public storage, logs, Git, Telegram messages, or ordinary status output.

## 8. QUIC Initial + Xray noises

The important technology from `lib/quic-initial.js` is that the first decoy packet is a real decryptable QUIC v1 Initial, not a static byte string.

Required properties:

- QUIC v1 Initial;
- RFC 9000 packet structure;
- RFC 9001 Initial key derivation;
- TLS 1.3 ClientHello;
- SNI;
- ALPN `h3`;
- X25519 key share;
- correct HKDF;
- AES-GCM payload encryption;
- header protection;
- valid packet length;
- browser-like profile;
- unique packet content across generations.

The implementation must not depend forever on one exact static JA4 value. Fingerprint profiles should be versioned test fixtures. The invariant is:

- profile is internally consistent and plausibly browser-like;
- packet decrypts and parses;
- content changes between generations;
- structural fingerprint stays within the selected versioned profile.

The WARP Xray shape is:

```text
outbound "warp"
  protocol: wireguard
  streamSettings.sockopt.dialerProxy -> "warp-noise"

outbound "warp-noise"
  protocol: freedom
  settings.noises:
    - valid QUIC Initial
    - randomized rand entries
```

Noise is an egress modifier only.

## 9. Endpoint pool instead of one hard-coded endpoint

Do not inherit `162.159.192.1:500` as an architectural constant.

Create a pool model:

```json
{
  "endpoints": [
    {
      "address": "host-or-ip:port",
      "source": "discovered|configured|last-good",
      "family": "ipv4|ipv6|name",
      "health": "healthy|degraded|down|unknown",
      "last_success": null,
      "last_failure": null,
      "rtt_ms": null,
      "failures": 0
    }
  ]
}
```

Endpoint selection policy:

1. operator-pinned healthy endpoint if configured;
2. healthy last-good endpoint;
3. discovered healthy pool;
4. no automatic downgrade to an untested endpoint.

Discovery and healthcheck are separate operations. DNS resolution alone is not proof that a WARP WireGuard endpoint works.

A failure must be able to fall back to `direct`, another healthy WARP endpoint, Hysteria2/client-transport policy, or an explicit fail-closed state depending on policy. The fallback decision belongs to the policy engine.

## 10. Policy engine

Introduce a small declarative policy model rather than embedding decisions in shell branches.

Example conceptual model:

```ini
POLICY_MODE=normal

FEATURE_EGRESS_WARP=0
FEATURE_WARP_QUIC_NOISE=0
FEATURE_AUTO_POLICY=0
FEATURE_ALTERNATE_ENDPOINT=0

EGRESS_BACKEND=direct
EGRESS_FALLBACK=direct

WARP_ENDPOINT_POLICY=health_pool
WARP_NOISE_PROFILE=quic-v1-browserlike-v1

HARDENED_ENABLE_EXTRA_SCANNERS=0
HARDENED_PREFER_HYSTERIA2=0
```

These names are architectural placeholders, not a frozen CLI.

Required policy modes:

### normal

- current inbound protection;
- current selected client transport;
- direct egress;
- no WARP/noise.

### hardened

- broader reviewed scanner classes;
- stricter detector thresholds;
- same transport unless another rule explicitly changes it;
- egress remains separately selectable.

### alternate-endpoint

- same transport family;
- choose another validated endpoint/origin where supported;
- no implicit WARP enable.

### hysteria2

- client transport preference changes to Hysteria2;
- egress remains independently direct/WARP.

### warp

- egress switches to WARP;
- client transport unchanged.

### warp-quic-noise

- egress switches to WARP;
- QUIC Initial + randomized freedom noises enabled;
- client transport unchanged.

## 11. Detector

Detector inputs are facts, not actions.

Potential facts:

- TSPU/GOV/scanner counters;
- repeated scanner hits;
- source update health;
- current firewall backend state;
- DNS/TLS/profile selftest;
- TCP/443 XHTTP health;
- UDP/443 Hysteria2 health;
- WARP endpoint health;
- direct egress health;
- packet-loss/timeout signals from real-network tests;
- optional operator-supplied classification.

Example JSON:

```json
{
  "schema": "remna-security.detector.v1",
  "signals": [
    {
      "id": "warp_endpoint_degraded",
      "severity": "warning",
      "source": "egress-health",
      "observed_at": "..."
    }
  ]
}
```

Automatic policy changes stay disabled until separately approved.

## 12. Machine API / CLI surface

Extend the current JSON-first approach instead of making AINOC scrape human output.

Proposed read-only commands:

```text
protection-manager.sh detector-status --json
protection-manager.sh policy-status --json
protection-manager.sh policy-evaluate --json
protection-manager.sh egress-status --json
protection-manager.sh egress-preflight --json
protection-manager.sh warp-status --json
protection-manager.sh warp-endpoints --json
protection-manager.sh warp-selftest --json
```

Proposed guarded mutations:

```text
protection-manager.sh policy-set <mode> --confirm
protection-manager.sh egress-set <direct|warp|warp-quic-noise> --confirm
protection-manager.sh warp-register --confirm
protection-manager.sh warp-endpoint-set <endpoint> --confirm
protection-manager.sh warp-rotate --confirm
protection-manager.sh rollback
```

Architecture schemas:

- `remna-security.detector.v1`
- `remna-security.policy.v1`
- `remna-egress.status.v1`
- `remna-egress.preflight.v1`
- `remna-warp.status.v1`
- `remna-warp.selftest.v1`

Do not expose WireGuard private keys or Cloudflare tokens in these schemas.

## 13. Rollback model

Every egress mutation must snapshot:

- selected backend;
- endpoint pool;
- chosen endpoint;
- WARP account metadata;
- generated outbound profile;
- noise profile version;
- policy state.

A failed apply restores the previous egress/profile state.

Rollback of egress must not roll back unrelated inbound firewall data, and firewall rollback must not delete valid WARP credentials. Snapshots may share an overall transaction id but must preserve layer ownership.

## 14. Tests before any real activation

### Offline/unit tests

- WARP keypair size/format;
- registration parser separates network/non-JSON/HTTP failures;
- non-idempotent registration is not blindly retried;
- secrets are root-only and redacted;
- endpoint parser covers IPv4/IPv6/name;
- endpoint pool selection is deterministic;
- unhealthy endpoint is not selected;
- last-good endpoint survives discovery failure;
- feature flags default OFF;
- policy evaluation does not mutate runtime;
- layer rollback does not damage another layer.

### QUIC cryptographic tests

- generated packet is QUIC v1 Initial;
- packet length is valid/configured;
- Initial keys derive correctly;
- header protection can be removed;
- AEAD decrypt succeeds;
- CRYPTO frame yields ClientHello;
- TLS 1.3 present;
- SNI present;
- ALPN includes `h3`;
- X25519 key share present;
- two generated packets are byte-different;
- selected fingerprint profile remains stable where intended.

### Xray config tests

- WireGuard outbound valid;
- `dialerProxy` points only to the dedicated freedom outbound;
- freedom outbound contains valid noises;
- direct and WARP routes are not accidentally both authoritative;
- generated configuration passes real Xray/rw-core config test where runtime supports the feature;
- failure leaves previous working profile installed.

### Integration tests in namespaces/VMs

- no global firewall flush;
- Docker/UFW rules survive;
- inbound scanner guard stays independent of egress;
- XHTTP/REALITY still works with direct egress;
- Hysteria2 still works with direct egress;
- XHTTP/REALITY works with WARP egress;
- Hysteria2 works with WARP egress where supported;
- endpoint failover;
- WARP disabled/removed returns to direct without reinstall.

### Real-network field matrix

Must be performed before enabling any automatic mode:

- several fixed broadband networks;
- several mobile operators;
- IPv4-only;
- dual-stack;
- CGNAT;
- networks where ordinary WireGuard is known to be impaired;
- packet loss/MTU constrained network.

Compare:

1. direct baseline;
2. plain WARP;
3. WARP + valid QUIC Initial only;
4. WARP + QUIC Initial + randomized noise;
5. Hysteria2;
6. alternate endpoint where applicable.

Collect success/failure, handshake latency, packet loss, throughput, reconnect behavior, endpoint stability and pcap evidence where lawful and available.

Do not declare "undetectable" or "bypass guaranteed". Treat this as empirical network compatibility/hardening work.

## 15. Implementation phases

### Phase A — architecture and contracts

- this document;
- config schema;
- JSON schema drafts;
- module interfaces;
- no runtime activation.

### Phase B — offline egress backend

- local WARP registration;
- local secret store;
- endpoint parser/pool;
- QUIC generator;
- Xray outbound builder;
- simulator/tests;
- feature flags remain OFF.

### Phase C — runtime preflight/selftest

- generate but do not activate;
- real `rw-core/Xray run -test`;
- endpoint healthcheck;
- rollback transaction;
- no automatic policy.

### Phase D — lab activation only

- explicit human approval;
- disposable/lab node;
- field matrix;
- evidence/handoff.

### Phase E — optional production rollout

Separate decision. Not authorized by this architecture.

## 16. Explicit non-goals

- no fork of `warp-xray-generator` unless a small vendored module is later justified;
- no Vercel dependency;
- no Upstash dependency;
- no public subscription service;
- no public storage of WARP private material;
- no fixed single endpoint as an invariant;
- no automatic WARP enablement;
- no automatic mode switching without a separately approved policy;
- no merging inbound scanner protection, client transport and egress into one config block;
- no second firewall owner;
- no second Remna security product.

## 17. Target V2 stack

```text
                +---------------------------+
                |        DETECTOR           |
                | RKN / scanners / health   |
                +-------------+-------------+
                              |
                              v
                +---------------------------+
                |       POLICY ENGINE       |
                +------+------+-------------+
                       |      |
          +------------+      +-------------------+
          v                                       v
+---------------------+                +----------------------+
| INBOUND PROTECTION  |                | CLIENT TRANSPORT     |
| REMNA_GUARD         |                | XHTTP / RAW / HYST2  |
| scanner sets        |                | self-steal           |
+---------------------+                +----------------------+
                              |
                              v
                   +----------------------+
                   | EGRESS BACKEND       |
                   | direct               |
                   | WARP                 |
                   | WARP + QUIC noise    |
                   +----------------------+
```

The policy engine coordinates the layers, but each layer keeps independent ownership, status, tests and rollback.
