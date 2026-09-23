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


## 18. Mandatory contracts before Phase B

These clarifications close the architecture-review gaps. They are requirements, not optional implementation notes.

### 18.1 WARP credential lifecycle

The implementation must not assume undocumented token expiry semantics. It must record only verified lifecycle facts:

- account creation timestamp;
- last successful authentication/use;
- any expiry/validity metadata actually returned by the WARP API;
- last rotation timestamp;
- last failure class;
- account generation id.

Rotation may be triggered by:

1. explicit operator request;
2. verified authentication/authorization failure;
3. a separately configured maximum local credential age;
4. a future server-provided expiry signal, if verified.

Non-idempotent registration is never blindly retried after an ambiguous timeout. A new registration creates a new local generation and does not destroy the last-known-good generation until the new account and route have passed selftest.

Cleanup must not invent Cloudflare API operations. If account disable/delete is not verified to exist and work safely, the implementation records an orphan-risk event instead of pretending cleanup succeeded.

### 18.2 Detector → policy evaluation gate

Detector facts never mutate runtime.

The policy engine has two outputs:

- `current_state`: what is active;
- `recommended_state`: a pure evaluation result.

A recommended transition is represented as a machine-readable plan with:

- triggering facts;
- target layer(s);
- proposed change;
- expected rollback id;
- risk class;
- whether human approval is required.

Example:

```text
fact: warp_endpoint_degraded
current egress: warp
recommendation: endpoint failover to healthy last-good
runtime mutation: NONE
approval: REQUIRED
```

`FEATURE_AUTO_POLICY=0` is the hard default and Phase B/C code must refuse automatic mutations while it is false. Enabling any future automatic policy is a separate reviewed feature, not a config toggle that silently activates behavior.

### 18.3 Endpoint discovery trust and health algorithm

Endpoint sources have ordered trust:

1. operator-pinned endpoint;
2. last-known-good endpoint from a previously successful WARP session;
3. endpoint returned by verified local registration metadata;
4. discovered candidates.

Mutable discovery never makes an endpoint active by itself.

Health state requires more than DNS resolution. A candidate becomes `healthy` only after a WARP-specific end-to-end probe succeeds through that candidate. The implementation may use a temporary test outbound/network namespace, but success must prove that traffic exits through the tested WARP path.

Minimum contract:

- bounded timeout;
- at least 2 successful probes before promoting an unknown candidate;
- consecutive failures before demotion;
- hysteresis/cooldown to prevent endpoint flapping;
- explicit `unknown` state after reboot until validated;
- no untested endpoint selected automatically;
- probe destination(s) must not be a single permanent external dependency.

Exact probe targets and thresholds are Phase B implementation details and must be configurable/tested.

### 18.4 Cross-layer ownership and rollback

Each plane has its own state generation:

- `inbound_generation`;
- `transport_generation`;
- `egress_generation`.

A policy recommendation may contain changes for more than one plane, but activation is a transaction of independently owned steps.

Example: WARP endpoint failure while inbound `hardened` is active:

- egress may fail over or roll back;
- inbound remains hardened;
- transport remains unchanged;
- an egress rollback must not restore old firewall sets;
- an inbound rollback must not touch WARP credentials or transport profiles.

If a multi-plane change is ever approved, each plane receives its own rollback snapshot under a common transaction id. Partial failure rolls back only the steps already changed, in reverse order, without crossing ownership boundaries.

### 18.5 QUIC-noise profile contract

Noise profiles are versioned immutable definitions, for example:

```text
quic-v1-browserlike-v1
quic-v1-browserlike-v2
```

A profile declares which structural fields are stable and which values are randomized.

Stable within one profile version may include:

- QUIC version;
- ALPN family;
- TLS version;
- cipher-suite set/order where required by the profile;
- supported extension set;
- signature-algorithm profile;
- general transport-parameter shape.

Randomized per generation may include:

- DCID/SCID where valid;
- packet number within the profile rules;
- TLS random;
- X25519 key share;
- SNI selected from the profile's approved pool;
- selected QUIC transport parameter values within bounded sets;
- extension ordering only if the selected fingerprint profile permits it;
- padding position/amount within valid packet-size rules;
- Xray `rand` noise realization.

The implementation must not claim one fixed JA4 is permanently browser-safe. Tests validate the selected profile fixture and cryptographic correctness.

Profile retirement is manual by default. A detector may report suspected profile degradation, but automatic profile rotation remains disabled. Rotation uses the normal egress transaction and rollback path.

Test requirement: generate at least 100 packets per profile fixture, decrypt/parse every packet, confirm required structural invariants, and confirm non-identical packet bytes across the sample.

### 18.6 JSON redaction contract

Machine APIs expose the minimum information needed for operations.

Always secret:

- WireGuard private key;
- WARP bearer token;
- raw authorization headers;
- full secret-bearing generated configs.

Normally visible:

- backend name;
- account generation id;
- endpoint address/pool health;
- public peer key if operationally required;
- non-secret interface addresses;
- timestamps;
- failure class;
- profile version;
- redacted content hashes.

Account identifiers are treated as sensitive metadata: ordinary status may expose only a stable local generation id or truncated/hash representation. No generic `--expose-sensitive` mode is required for V2.

### 18.7 Persistent last-known-good and snapshots

State is stored under the owned root, conceptually:

```text
/opt/remna-protection/
  snapshots/
  egress/
  data/lkg/
```

Snapshot writes use:

1. write temp file in the same filesystem;
2. fsync file;
3. atomic rename;
4. fsync parent directory where practical;
5. only then mark the generation committed.

Every snapshot contains:

- schema version;
- transaction id;
- layer;
- generation;
- timestamp;
- non-secret content hashes;
- pointer to encrypted/root-only secret material where applicable.

Retention default: current + five previous committed generations per layer. Cleanup happens only after a successful committed transaction; failed/uncommitted snapshots are retained long enough for diagnostics and bounded by a separate cleanup policy.

### 18.8 Detector aggregation and staleness

Detector facts include:

- `observed_at`;
- `source`;
- `severity`;
- `confidence`;
- `ttl_seconds`;
- deduplication key;
- occurrence count.

The default aggregation window is one minute. Repeated identical facts inside the window increment a count instead of appending unbounded events. Stale facts expire before policy evaluation. Queue/file size is bounded; overflow drops oldest low-severity expired/duplicate facts first and records an overflow event.

Policy evaluation must not treat expired facts as active evidence.

### 18.9 Atomic Xray/rw-core config activation

Configuration activation is separate from generation and validation.

Required sequence:

1. generate candidate in a temp/root-only file;
2. parse/semantic validation;
3. real `rw-core/Xray run -test` against candidate;
4. snapshot current live config;
5. atomic rename candidate into place;
6. perform the documented runtime reload/restart mechanism for the installed core;
7. verify listeners/routes/end-to-end health;
8. on failure, atomically restore previous config, reload/restart, and verify rollback.

The concrete reload mechanism must be detected from the installed Remnawave/runtime version; V2 must not assume SIGHUP works unless verified.

### 18.10 Feature flag storage and validation

Feature flags live in one owned root-only policy file managed by the same config engine, not in ad-hoc shell environment.

Rules include:

- `FEATURE_EGRESS_WARP=0` by default;
- `FEATURE_WARP_QUIC_NOISE=0` by default;
- QUIC-noise requires WARP feature support;
- active egress `warp_quic_noise` requires both flags;
- `FEATURE_AUTO_POLICY=0` remains enforced before every mutating policy operation;
- incompatible combinations fail preflight instead of being auto-corrected.

Status reports configured and effective flags separately.

### 18.11 Phase D acceptance gate

Phase D remains lab-only and requires explicit human approval.

Minimum field evidence before any production proposal:

- at least 3 independent fixed broadband networks;
- at least 2 independent mobile networks/operators where available;
- at least 1 CGNAT path;
- IPv4-only and dual-stack coverage;
- at least one constrained-loss/MTU scenario.

Critical paths:

1. direct baseline;
2. plain WARP;
3. WARP endpoint failover;
4. WARP + QUIC-noise;
5. Hysteria2 baseline;
6. rollback to the previous known-good state.

A failed critical path blocks production proposal until the failure is explained and classified as either a code defect, provider limitation, or known network policy. No success percentage is allowed to hide an unexplained critical failure.

### 18.12 Noise-profile migration

A profile upgrade is explicit:

1. add a new immutable profile fixture;
2. run offline cryptographic/fingerprint tests;
3. run lab field tests;
4. mark old profile `deprecated`, not deleted;
5. detector may recommend migration;
6. operator approves migration;
7. egress transaction activates the new profile;
8. rollback can restore the previous profile and endpoint generation.

No scheduled automatic rotation is part of V2 by default.

## 19. Phase A/B definition after review

Phase A is complete only when the following contracts exist in code/docs:

- feature/config schema;
- detector fact schema and aggregation rules;
- policy recommendation schema and approval gate;
- per-layer snapshot/transaction schema;
- endpoint health interface;
- WARP secret/redaction schema;
- versioned QUIC profile schema;
- Xray activation interface;
- test matrix definitions.

Phase B remains offline-by-default:

- it may register WARP only when explicitly invoked in a controlled test context;
- it may generate configs, credentials and QUIC packets locally;
- it must not alter production routes, firewall state, client transport or live Remnawave profiles;
- feature flags remain OFF;
- policy evaluation remains advisory;
- all runtime mutation commands remain guarded and inactive until later approval.


## 20. Final review clarifications

These points make the remaining Phase A/B contracts explicit so that they are not left as implicit follow-up decisions.

### 20.1 Endpoint probe redundancy and state thresholds

A WARP endpoint health probe set must contain at least two independently configurable public targets that do not share one operational dependency. At least one probe must prove actual routed egress through the candidate WARP path; DNS resolution of the endpoint itself never counts as health.

Default state machine for Phase B tests:

- `unknown -> healthy`: two consecutive successful end-to-end probes;
- `healthy -> degraded`: two consecutive failed probes;
- `degraded -> down`: one additional failed probe after the degraded state;
- any successful recovery probe resets the consecutive-failure counter;
- after a state transition, a configurable cooldown prevents immediate oscillation;
- an endpoint in `unknown` or `down` is never selected automatically.

The exact timeout values and probe targets remain configurable, but tests must cover the above transition semantics and silent UDP/WireGuard blackhole behavior.

### 20.2 Detector TTL semantics

A detector fact is active evidence only while:

```text
now < observed_at + ttl_seconds
```

Expiration is evaluated before every policy evaluation. Expired facts:

- cannot trigger or sustain a recommendation;
- remain visible only in bounded recent-history telemetry;
- do not contribute to confidence or occurrence thresholds.

If multiple facts share a deduplication key, the newest observation extends the active window and increments the occurrence count; it does not create an unbounded queue.

### 20.3 Snapshot retention bounds

Committed state keeps:

- current generation;
- five previous committed generations per layer.

Failed or uncommitted transaction artifacts are retained for diagnostics for at most 72 hours and at most 20 generations per layer, whichever bound is reached first. Cleanup runs only after a committed transaction or explicit maintenance action and never deletes the current/last-known-good committed generations.

If cleanup itself fails, runtime state remains unchanged and a bounded telemetry event is recorded.

### 20.4 Xray/rw-core reload detection contract

Phase B/C must implement runtime capability detection before activation code is allowed to choose a reload method.

The detection result records:

- installed Remnawave/rw-core version where discoverable;
- execution model (host binary/container);
- supported config-test command;
- verified reload capability, if any;
- fallback restart mechanism.

Rules:

- never send SIGHUP or another signal merely because a generic Xray build might support it;
- if a safe reload mechanism cannot be verified, use the documented controlled restart path for that runtime;
- restart/reload failure immediately invokes the atomic rollback sequence from section 18.9;
- the old config must be re-tested and post-rollback listeners/end-to-end health verified.

### 20.5 Phase A deliverable checklist

Phase A is not considered complete unless it contains all of the following as explicit schemas/contracts:

- feature flags with hard defaults `FEATURE_EGRESS_WARP=0`, `FEATURE_WARP_QUIC_NOISE=0`, `FEATURE_AUTO_POLICY=0`;
- incompatible-feature validation;
- detector fact schema with TTL/staleness rules;
- policy recommendation schema including an explicit `approval_required` field;
- endpoint health state machine and probe interface;
- WARP credential generation/lifecycle schema including orphan-risk events;
- secret/redaction schema;
- per-layer transaction/snapshot schema and bounded retention policy;
- versioned QUIC-noise profile schema;
- Xray/rw-core activation capability interface;
- Phase D hard-gate field-test checklist.

### 20.6 Phase B implementation checklist

Phase B tests must explicitly verify:

- feature gates are checked before every mutating WARP/policy operation;
- `FEATURE_AUTO_POLICY=0` makes evaluation advisory-only;
- non-idempotent WARP registration is not retried after ambiguous failure;
- orphan-risk is recorded when remote account cleanup cannot be verified;
- endpoint health transitions and cooldown work as specified;
- expired detector facts never drive recommendations;
- at least 100 QUIC packets per fixture pass decrypt/parse/invariant tests and differ at byte level;
- per-layer rollback cannot mutate another plane;
- snapshot cleanup obeys both age and count bounds;
- runtime reload/restart capability detection fails closed;
- no production route, firewall state, client transport or live Remnawave profile is changed by the offline/default test path.

These are acceptance requirements already inside the AINOC implementation task; they are not deferred architecture questions.


## 20. Second-review closure

The second independent Claude review found no high/medium architecture blockers and classified the remaining points as low/info. These are closed here so Phase A/B acceptance criteria are explicit.

### 20.1 Detector absolute retention

In addition to per-fact TTL and one-minute aggregation, the detector store has an absolute retention ceiling.

- default maximum retained age: 24 hours;
- a fact with a shorter declared TTL expires earlier;
- expired facts are never fed into policy evaluation;
- high-severity expired facts may be summarized into audit history, but not retained as active detector facts;
- queue cleanup must be deterministic and bounded.

### 20.2 Probe target diversity

Endpoint health must not depend on one permanent probe destination.

The Phase B health implementation must use a configurable probe set with at least two independent targets from different failure domains when practical. Probe rotation is deterministic/round-robin with jitter; a target failure is distinguished from WARP path failure when other targets succeed.

A WARP endpoint is not promoted solely because one external service happened to answer once. Promotion requires the endpoint-level success criteria from section 18.3 across the configured probe set.

### 20.3 fsync portability

Atomic snapshot durability follows the section 18.7 sequence where supported.

- file fsync is required before rename;
- parent-directory fsync is attempted on supported local filesystems;
- unsupported directory-fsync behavior must not corrupt or abort an otherwise valid transaction;
- the implementation records the durability capability in preflight/status;
- tests cover both supported and gracefully-degraded filesystem behavior.

### 20.4 Phase A required artifacts are mandatory

Phase A implementation is not complete until it provides formal machine-readable contracts for:

- detector facts;
- policy recommendations;
- per-layer snapshots and common transaction ids;
- feature flags and compatibility validation;
- WARP status/redaction;
- endpoint health records;
- versioned QUIC-noise profile definitions;
- Xray/rw-core activation plan/result.

Each schema must have positive and negative fixtures/tests.

### 20.5 Phase B hard guards

Before any mutating Phase B code path:

- effective `FEATURE_AUTO_POLICY` must be `0`;
- effective `FEATURE_EGRESS_WARP` and `FEATURE_WARP_QUIC_NOISE` remain `0` unless an explicitly scoped lab/test command enables generation/registration behavior without changing production routes;
- no Phase B command may alter the live inbound firewall, live client transport, or live production egress route;
- a guard failure is fail-closed and machine-readable.

### 20.6 Runtime reload compatibility

The Xray/rw-core activation interface must detect the installed runtime/version and select a verified reload/restart method.

Unknown runtime/version means activation is refused. There is no optimistic SIGHUP fallback.

### 20.7 Snapshot cleanup versus rollback

Snapshot retention cleanup runs only after a transaction is fully committed and no rollback operation is active.

Cleanup must hold the same layer/transaction lock used by mutation/rollback so it cannot delete a generation referenced by an in-progress rollback.

### 20.8 Enforced three-plane transaction ownership

Implementation code must carry an explicit layer id on every mutation and snapshot.

A transaction dispatcher must reject a step if it attempts to write an object owned by another layer. Cross-layer policy plans may contain multiple steps, but each step remains independently owned and independently reversible.

### 20.9 QUIC profile load-time validation

A QUIC-noise profile is immutable by version id and content hash.

- mixed-version structural fragments are rejected;
- unknown profile versions are rejected;
- duplicate version ids with different content hashes are rejected;
- active status exposes version id plus non-secret content hash;
- profile migration follows section 18.12.

### 20.10 Account identifier redaction

External/machine status does not expose raw WARP account identifiers by default.

It exposes a local generation id and, when correlation is needed, a truncated cryptographic hash of the provider account id. Logs follow the same rule. Raw account id, bearer token and private key remain confined to root-only secret state.

### 20.11 Phase D evidence gate

The Phase D matrix from section 18.11 must be stored as evidence with:

- network class/operator label;
- date/time;
- code/config/profile versions;
- pass/fail per critical path;
- failure classification;
- reviewer/human sign-off.

No production proposal may be generated while a required matrix row is missing or contains an unexplained critical failure.

### 20.12 Pre-Phase-C contract checkpoint

Before Phase C can start, AINOC must run a dedicated contract audit proving that all sections 18 and 20 are represented in implementation and tests.

Phase C remains blocked if any mandatory contract is missing, untested, or only documented but not enforced.
