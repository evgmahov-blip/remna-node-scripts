# Architecture: selective CheburNET adoption for REMNANODE NEXT

Status: architecture candidate only. No live activation, no firewall mutation, no transport cutover.

Reference source reviewed:
- `leonidkopysov/CheburNET-Vision-Installer` main, release line 1.1.4
- `evgmahov-blip/remna-node-scripts` current main

## Goal

Adopt the strongest lifecycle, validation and observability ideas from CheburNET without replacing the current REMNANODE NEXT transport model, without creating another firewall owner, and without weakening provenance or release gates.

The target remains:

`REMNANODE NEXT + Remna Security + Security V2 + AINOC release workflow`

CheburNET is treated as a reference implementation, not as an upstream runtime dependency.

## Non-goals

This architecture does NOT:
- replace XHTTP/REALITY with TLS Vision;
- replace RAW/REALITY or Hysteria2;
- introduce CheburNET Traffic Control as a second firewall;
- consume mutable external scanner lists directly;
- add global UFW ownership;
- add automatic OS-wide mutation as a monolithic installer step;
- allow force-pushed tags or mutable releases;
- make Let's Encrypt mandatory for the whole node;
- merge inbound, transport and egress ownership.

## Ownership model

Existing Security V2 ownership remains authoritative.

| Area | Owner |
| --- | --- |
| Inbound protection | Remna Security / existing owned chains and sets |
| Client transport | NEXT transport manager |
| Egress | Security V2 egress plane |
| Installer lifecycle | NEXT lifecycle controller |
| Verification | read-only verification layer |
| Host tuning | existing network/system tuning managers |
| Observability | read-only counters/events/reporting |

Installer lifecycle and verification are control layers, not new security planes.

## A. Transactional installer lifecycle

Introduce an explicit lifecycle state machine for NEXT.

States:

`NEW -> STAGING -> PRECHECKED -> APPLYING -> POSTCHECK -> COMPLETE`

Failure transitions:

`* -> FAILED_RECOVERABLE`

`FAILED_RECOVERABLE -> RESUME`

No implicit restart from scratch.

Required state artifacts under a root-owned lifecycle directory:
- transaction id;
- source commit/blob provenance;
- requested mode;
- completed steps;
- current step;
- previous known-good pointers;
- pending marker;
- completion marker;
- structured error class.

Writes must use temp file -> fsync -> rename -> parent fsync where supported.

The lifecycle controller must not become the owner of firewall or transport config. It only coordinates existing managers.

Commands:

`remnanode-next install`
`remnanode-next resume`
`remnanode-next lifecycle-status`
`remnanode-next lifecycle-status --json`

A repeated install against COMPLETE must refuse destructive work and degrade to verification unless an explicit reinstall/migration command is used.

## B. Secret and panel credential preflight

Add deep validation before any destructive node changes.

For Remnawave node secret material:
- strict decode;
- expected object shape;
- CA certificate parse;
- node certificate parse;
- node private key parse;
- node cert validity window;
- node cert chain validation;
- node cert/private-key correspondence;
- JWT public key parse;
- no secret value in normal output or JSON diagnostics.

Failure is a PRECHECK failure and must happen before firewall, package or transport mutation.

Expose only redacted facts:

`secret_present`
`secret_structure_valid`
`certificate_chain_valid`
`certificate_time_valid`
`private_key_matches`
`jwt_key_valid`

## C. Container image provenance

Keep current immutable source-script provenance and extend the same principle to runtime images.

Install flow:

`configured image reference -> pull -> resolve digest -> persist digest -> run by digest`

Rules:
- mutable tags may be used only as discovery inputs when policy permits;
- the active generation stores the resolved digest;
- restart/recovery uses the persisted digest;
- upgrade requires a new candidate transaction and verification;
- no silent image drift.

Verification JSON includes expected and active digest without credentials.

## D. Unified read-only verification

Add one authoritative read-only entry point:

`remnanode-next verify`
`remnanode-next verify --json`

It aggregates existing component checks instead of duplicating ownership.

Minimum domains:
- Remnawave container/runtime;
- active image digest;
- XHTTP/REALITY;
- RAW/REALITY when configured;
- Hysteria2 when configured;
- SelfSteal socket and nginx;
- panel API exposure;
- inbound protection status;
- runtime guard drift;
- required secret/file permissions;
- certificate state for TLS-dependent transports;
- network tuning state;
- Telemt when configured;
- systemd timers/services owned by this project.

Result classes:

`PASS`
`WARN`
`FAIL`
`NOT_CONFIGURED`
`UNKNOWN`

Unknown must never be rendered as PASS.

JSON schema should be versioned and stable for AINOC/Telegram use.

Verification is read-only. Repair remains an explicit separate action.

## E. Safe configuration mutation contract

Generalize the strongest pattern from CheburNET SSH hardening into a reusable mutation contract.

For any high-risk config mutation:

`snapshot -> render candidate -> syntax validation -> semantic diff -> apply -> reload/restart using detected method -> postcheck -> rollback on failure`

Required invariants:
- never assume SIGHUP support;
- do not overwrite unknown foreign config blindly;
- detect symlinks where unsafe;
- preserve unrelated authentication/network settings;
- rollback must restore only owned state;
- postcheck must verify effective state, not just file contents.

First intended consumers:
- SSH hardening if/when NEXT owns a narrow SSH policy;
- systemd drop-ins;
- sysctl fragments;
- transport profile activation;
- owned service configuration.

## F. Observability and blocked-source analytics

Add a read-only observability layer over existing firewall counters and journals.

Do not create a second filtering engine.

Capabilities:
- per-category counters;
- top blocked IPs over a bounded window;
- optional RDAP/ASN enrichment with cache;
- rate-limited logging only;
- no assumption that network owner equals attacker;
- machine-readable summary for AINOC/Telegram.

Expected categories follow the existing Remna Security catalog.

Example JSON fields:
- window_start/window_end;
- blocked_total;
- unique_sources;
- by_category;
- top_sources;
- data_completeness;
- logging_mode.

Enrichment failure must not affect protection.

## G. Host health and tuning inspection

Expand diagnostics without turning tuning into a monolithic hardening product.

Read-only checks may include:
- CPU topology;
- IRQ/RPS state;
- NIC queues;
- current BBR/qdisc;
- file limits;
- conntrack usage versus limit;
- memory pressure;
- ZRAM presence/status;
- disk free space;
- inode pressure;
- NTP state;
- TRIM support/state;
- Docker limits;
- kernel and virtualization constraints.

Output must distinguish:
- observed fact;
- recommendation;
- mutation required.

Applying changes remains explicit and profile-driven.

Do not automatically enable ZRAM, change SSH, change firewall ownership or install a custom kernel as a side effect of health inspection.

## H. Testing strategy

Keep architectural grep guards where they protect hard invariants, but shift new functionality toward behavioral tests.

Required test families:
- lifecycle transition tests;
- interrupted install/resume tests;
- idempotence tests;
- corrupt state tests;
- secret validation fixtures;
- certificate/key mismatch fixtures;
- image digest resolution/persistence tests;
- verify JSON schema tests;
- UNKNOWN != PASS tests;
- mutation rollback tests;
- semantic-effective-state tests;
- observability parsing tests;
- no-global-firewall-mutation tests.

External commands must be injectable/fakeable in offline tests.

No live VPS result may be implied by offline CI.

## I. Release and trust rules

Do not copy CheburNET mutable-release behavior.

For this project:
- no force push;
- no forced retagging;
- published releases are immutable;
- candidate approval != release approval;
- GitHub release != live node activation;
- live infrastructure activation remains a separate gate;
- provenance must identify exact commit and relevant blob/digest values.

## J. Delivery phases

### Phase 1 - contracts only
- lifecycle schema/state model;
- verify JSON schema;
- secret validation module contract;
- image provenance contract;
- mutation transaction contract;
- tests only, no live activation changes.

### Phase 2 - read-only implementation
- `verify`;
- host-health inspection;
- observability aggregation;
- secret preflight;
- image digest inspection;
- all mutation paths disabled.

### Phase 3 - installer lifecycle
- staging/pending/complete markers;
- resume;
- idempotence;
- explicit recovery;
- still no new firewall owner.

### Phase 4 - safe mutation framework
- reusable snapshot/validate/apply/postcheck/rollback primitive;
- migrate selected existing mutations onto it one at a time.

### Phase 5 - lab validation
- clean install;
- interrupted install;
- resume;
- reboot;
- existing-node migration;
- XHTTP;
- RAW;
- Hysteria2;
- combined mode;
- panel reconnect;
- RKN protection;
- Telemt;
- rollback drills.

### Phase 6 - production decision
Separate human approval. Not implied by merge or release.

## K. Explicitly rejected CheburNET ideas

Rejected for this architecture:
- CheburNET Traffic Control as an additional nftables firewall owner;
- mutable scanner source trust;
- mandatory TLS Vision transport;
- mandatory Let's Encrypt for the node;
- broad OS mutation bundled into one unavoidable install step;
- force-update of existing release tags;
- treating component process existence as sufficient health.

## L. Acceptance criteria

Architecture is acceptable only if review confirms:
1. no second firewall owner;
2. no regression of existing pinned/LKG trust model;
3. no transport replacement;
4. lifecycle state cannot silently skip failed steps;
5. resume is idempotent;
6. verification is read-only;
7. UNKNOWN is fail-safe and never PASS;
8. secrets are redacted;
9. image drift is prevented after digest resolution;
10. rollback is owner-scoped;
11. no force-push/re-tag release path;
12. no live activation is introduced by this change.

## M. Implementation sequencing recommendation

Preferred implementation order:

`secret preflight -> verify -> image digest pinning -> lifecycle/resume -> observability -> host health -> safe mutation framework`

Reason: the first three improve correctness and evidence with minimal live-state risk; transactional lifecycle follows once verification is strong enough to decide whether resume/commit succeeded.
