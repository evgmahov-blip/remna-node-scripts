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

### Cross-manager transaction contract

The lifecycle controller may coordinate a mutating manager only through a versioned coordinator-to-manager interface. Direct mutation calls that bypass this interface are forbidden while a lifecycle transaction is active.

The interface must expose:
- manager name and schema version;
- transaction id and operation id;
- owned layer/object identifiers;
- expected current generation/fingerprint;
- proposed next generation/fingerprint;
- precondition result;
- prepare result;
- commit acknowledgement;
- postcheck evidence;
- rollback capability and rollback generation.

Security V2 locking remains authoritative. Any lifecycle transaction touching more than one Security V2 plane MUST acquire locks in the existing order:

`transaction -> inbound -> transport -> egress`

All non-Security-V2 mutating managers named by this architecture (package manager, container runtime, systemd drop-ins, sysctl fragments, certificate issuance/renewal and future lifecycle-owned mutators) are serialized behind the single lifecycle transaction lock. They must not introduce independent cross-manager lock ordering outside their own private internal lock after the lifecycle transaction lock is held.

The lifecycle controller must never invent a competing Security V2 lock order. If a required manager cannot participate in the common transaction/lock contract, the operation stops with `MANUAL_RECOVERY_REQUIRED`; it must not fall back to best-effort coordination.

Every mutating manager entry point must reject or join an active coordinator transaction rather than mutate concurrently behind it.

### Lock identity, fencing and stale-lock handling

The transaction lock is not a bare pidfile. Its durable ownership record must contain:
- transaction id;
- holder boot id;
- holder process identity;
- monotonic acquisition generation;
- fencing token;
- acquired_at;
- last heartbeat/liveness observation where applicable.

Every mutating manager call made under a lifecycle transaction must receive and validate the current fencing token before mutation and again before commit acknowledgement.

A resumed controller never assumes that a previous process still owns the lock. It must reconcile lock owner identity, boot id, liveness and journal state.

Stale-lock policy is fail-closed:
- a dead holder does not authorize silent lock breaking;
- the controller records stale-lock evidence;
- it may reacquire only through the documented recovery path after proving the previous holder cannot still mutate;
- uncertainty becomes `MANUAL_RECOVERY_REQUIRED`;
- fencing generation/token changes on any legitimate reacquisition, making late writes from an old holder invalid.

### Durable journal and crash recovery

A lifecycle transaction uses one durable append/replace journal whose records bind lifecycle intent to manager state. Each operation record must include:
- transaction id;
- unique operation id;
- step name;
- idempotence class;
- expected-before generation/fingerprint;
- manager prepare evidence;
- manager commit acknowledgement;
- expected-after generation/fingerprint;
- observed effective runtime state;
- rollback reference;
- timestamp and journal schema version.

A lifecycle step is considered committed only after both:
1. the manager has committed and returned durable commit evidence; and
2. the lifecycle journal has durably recorded that exact manager generation/fingerprint.

Journal integrity is mandatory:
- each record has schema version, sequence number and checksum/hash over canonical serialized content;
- a transaction header binds the journal to transaction id and candidate/release provenance;
- writes use temp -> fsync -> rename/append discipline appropriate to the chosen journal format;
- truncated, torn, checksum-invalid, duplicate-sequence or out-of-order records are rejected;
- unknown/newer schema versions are never auto-downgraded;
- any journal-integrity ambiguity becomes `MANUAL_RECOVERY_REQUIRED`.

On startup/resume, the controller must reconcile the journal against each manager's actual current generation and effective runtime state before taking any action. Marker presence alone is never proof of success.

Ambiguous states MUST stop fail-closed as `MANUAL_RECOVERY_REQUIRED`. Resume must never guess whether an external mutation succeeded.

### Per-step idempotence

Every lifecycle step must declare one of:
- `IDEMPOTENT_RETRY`;
- `RECONCILE_THEN_RETRY`;
- `NON_RETRYABLE_MANUAL`.

Each step contract must define:
- preconditions;
- postconditions;
- retry key / operation id semantics;
- externally visible side effects;
- timeout semantics;
- reconciliation method;
- rollback method;
- whether retry after an ambiguous timeout is forbidden.

Non-idempotent effects such as certificate issuance, panel/API writes, package transactions, service restarts, image replacement, or other external calls must never be retried solely from a local marker.

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

Secret handling is a no-persist/no-log contract:
- decoded private material stays in memory where feasible;
- no private material in argv, subprocess environment, exception text, tracebacks, systemd journal fields, lifecycle journal, snapshots, telemetry, test fixtures, caches, or normal temporary files;
- if temporary storage is unavoidable, it must be root-only, mode 0600 or stricter, on an approved private directory, short-lived, and securely removed on all exit paths;
- validation helpers return booleans/fingerprints only, never the private value;
- crash/debug modes must not dump secret-bearing buffers;
- failure to establish secure handling is itself a PRECHECK failure.

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

Digest pinning is necessary but not sufficient for trust. The runtime image trust policy must also define:
- allowlisted registries and repository identities;
- TLS/authentication requirements for registry access;
- OCI manifest/index handling;
- selected OS/architecture/platform;
- the exact platform-specific manifest digest;
- optional/required signature or attestation verification policy;
- pinned trusted signer/issuer identity or key material;
- provenance/SBOM linkage where available;
- proof that the running container image ID/RepoDigest corresponds to the approved platform-specific digest.

A digest first observed from an untrusted or unauthorized registry is not automatically trusted merely because it is immutable.

Rollback must record and restore an exact previously verified image ID/digest, never a mutable tag.

The last-known-good rollback image is a protected rollback asset:
- its exact image ID and platform digest are recorded in the transaction/release evidence;
- local pruning/GC must exclude it while it is the active rollback target;
- replacement of the rollback target happens only after the new generation reaches COMPLETE and the retention policy commits the new LKG;
- rollback does not depend on resolving a mutable tag;
- if the exact LKG image is absent and the registry cannot provide the already-approved digest, rollback is declared unavailable and the transaction stops at `MANUAL_RECOVERY_REQUIRED`; no substitute image may be selected.

Verification JSON includes expected and active digest, platform, trust-verification result and provenance identifiers without credentials.

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

Required-check aggregation is deterministic:
- any required `FAIL` => overall `FAIL`, nonzero exit;
- any required `UNKNOWN` => overall `UNKNOWN`, nonzero exit;
- required checks all `PASS`/allowed `WARN` => overall success according to the versioned policy;
- `NOT_CONFIGURED` is accepted only for components explicitly declared optional/not configured;
- missing or malformed expected checks => `UNKNOWN`, nonzero exit.

Every check reports:
- check id and schema version;
- required/optional flag;
- observed_at;
- freshness/TTL;
- timeout;
- evidence source;
- status;
- reason code.

Verification adapters operate under a capability-restricted read-only contract. They may not:
- pull or run images;
- install packages;
- reload/restart services;
- change firewall/routing/sysctl;
- rotate credentials/certificates;
- write panel state;
- invoke repair-capable manager commands;
- create persistent state as a side effect.

Network reads are allowed only when explicitly declared by a check and bounded by timeout. Any cache must be bounded, non-secret, optional, and outside authoritative state; cache failure cannot trigger mutation.

The required/optional/WARN aggregation policy is itself an immutable release input:
- it is versioned and content-hashed;
- its hash is bound into release evidence;
- verify prints the policy version/hash it used;
- missing, mismatched, untrusted or newer-unknown policy => overall `UNKNOWN`, nonzero exit;
- a node-local setting may not weaken required checks or convert required UNKNOWN/FAIL into success.

Read-only is enforced at runtime, not only by tests. Mutating manager entry points require a mutation-gate token/context that is issued only by an authorized lifecycle mutation transaction. Verify, inspect, status, health and preflight contexts never receive such a token. A mutation-capable manager called without a valid mutation gate must fail before side effects.

Where practical, read-only commands also run with reduced OS privileges/capabilities. Runtime mutation-gate enforcement remains mandatory even when privilege separation is unavailable.

JSON schema should be versioned and stable for AINOC/Telegram use.

Verification is read-only. Repair remains an explicit separate action and a separate gate.

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
- postcheck must verify effective state, not just file contents;
- every owned object has an ownership fingerprint and generation/version;
- mutation uses compare-and-swap style preconditions against the expected generation/fingerprint;
- the relevant manager lock is held from snapshot through apply, postcheck, journal commit and cleanup;
- any unexpected concurrent change causes refusal, not overwrite;
- rollback also requires the expected post-mutation generation/fingerprint and refuses to clobber a newer state;
- a refused rollback preserves evidence and returns `MANUAL_RECOVERY_REQUIRED`.

For multi-manager transactions, rollback is tracked per manager/object. The journal records `ROLLED_BACK`, `ROLLBACK_REFUSED`, `ROLLBACK_FAILED`, or `NOT_TOUCHED` for every participant together with the generation left active.

A partial rollback produces one bounded `MIXED_GENERATION_MANUAL_RECOVERY` state. Its operator-facing report must identify:
- transaction id;
- candidate and previous generation;
- each manager/object;
- current observed generation/fingerprint;
- rollback outcome;
- remaining candidate-owned objects;
- safe actions allowed next.

No automatic forward progress, new mutation transaction, release, or activation is permitted while this mixed state is unresolved.

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
- interrupted install/resume tests at every journal/manager commit boundary;
- reconciliation tests for manager-committed/journal-not-committed and journal-committed/runtime-not-effective states;
- idempotence-class tests for every lifecycle step;
- ambiguous timeout => manual recovery tests for non-retryable effects;
- cross-manager lock-order/deadlock tests;
- concurrent direct-manager invocation refusal tests;
- corrupt state tests;
- secret validation fixtures;
- certificate/key mismatch fixtures;
- no-secret-in-argv/env/log/journal/traceback/temp-artifact tests;
- secret-handling tests ensure core dumps are disabled for secret-processing helpers where supported;
- image digest resolution/persistence tests;
- registry allowlist/platform-manifest/image-ID binding tests;
- signature/attestation policy tests where enabled;
- verify JSON schema tests;
- required UNKNOWN => nonzero aggregate tests;
- verify no-hidden-mutation tests;
- mutation rollback tests;
- concurrent-change/CAS rollback-refusal tests;
- semantic-effective-state tests;
- observability parsing tests;
- no-global-firewall-mutation tests;
- release provenance binding tests;
- stale-lock/fencing-token rejection tests;
- torn/truncated/bad-checksum journal tests;
- LKG image retention/pruning-protection tests;
- mixed-generation partial-rollback reporting/blocking tests;
- runtime mutation-gate refusal tests for verify/preflight contexts;
- verify-policy hash mismatch => UNKNOWN/nonzero tests;
- trust-policy downgrade/revocation/expiry tests.

External commands must be injectable/fakeable in offline tests.

No live VPS result may be implied by offline CI.

## I. Release and trust rules

Do not copy CheburNET mutable-release behavior.

For this project:
- no force push;
- no forced retagging;
- protected release refs/tags;
- published releases are immutable;
- candidate approval != release approval;
- GitHub release != live node activation;
- live infrastructure activation remains a separate gate;
- provenance must identify exact commit and relevant blob/digest values.

Release evidence must bind, in one immutable record:
- reviewed candidate commit;
- relevant source blob hashes;
- generated release artifact hashes;
- installer/package manifest;
- SBOM/provenance attestation where generated;
- approved runtime image platform digest;
- review evidence identifiers;
- release approval identifier.

Trust strength is pinned by release evidence and is non-downgradeable at install time.

The release trust policy declares whether signatures/attestations are required and binds:
- trusted signer/issuer identities or keys;
- allowed signature/attestation types;
- key/issuer validity window;
- rotation generation;
- revocation source/policy;
- attestation expiry/freshness policy;
- minimum trust level.

A node-local setting cannot disable a release-required signature/attestation check or replace trusted identities. Unknown signer rotation, revoked signer, expired required attestation, missing trust policy, or attempted downgrade fails closed.

Signed commit/tag/artifact provenance, where required by that pinned policy, must be verified against the exact trusted identities/keys from release evidence. Unsigned or unverifiable artifacts must not silently substitute for a signed-required policy.

A future installer may select only an artifact/digest that matches the approved immutable release evidence. A GitHub release page or tag name by itself is not trust evidence.

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
- all mutation paths disabled;
- explicit no-hidden-activation enforcement;
- tests prove these commands cannot call mutation-capable manager paths, pull/run images, reload/restart services, alter firewall/routing/sysctl, rotate credentials/certificates, or change panel state.

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
4. Security V2 lock order remains authoritative and cross-manager mutation uses one versioned coordinator contract;
5. lifecycle state cannot silently skip failed steps;
6. durable journal reconciliation handles crashes between manager commit and lifecycle recording;
7. every lifecycle step has explicit idempotence/retry/recovery semantics;
8. verification is capability-restricted read-only;
9. required UNKNOWN is fail-safe, never PASS, and returns nonzero;
10. secrets are never persisted/logged/leaked through argv/env/journal/tracebacks;
11. image drift is prevented and image trust binds registry identity, platform digest and executed image;
12. rollback is owner-scoped and generation/CAS protected against concurrent changes;
13. release evidence immutably binds reviewed source, artifacts and runtime image digest;
14. transaction locks have fencing/stale-holder semantics and all non-V2 mutators are serialized behind the lifecycle transaction lock;
15. journal integrity detects torn/truncated/corrupt/unknown-schema records fail-closed;
16. the exact LKG image remains retained/protected while it is a rollback target;
17. partial rollback becomes a bounded mixed-generation manual-recovery state and blocks new mutation/release/activation;
18. verify/preflight are runtime-enforced read-only through a mutation gate, not merely CI convention;
19. verify policy and release trust/signing policy are hash-bound/non-downgradeable release inputs;
20. no force-push/re-tag release path;
21. inspect/preflight/verify contain no hidden activation path;
22. no live activation is introduced by this change.

## M. Implementation sequencing recommendation

Preferred implementation order:

`secret preflight -> verify -> image digest pinning -> lifecycle/resume -> observability -> host health -> safe mutation framework`

Reason: the first three improve correctness and evidence with minimal live-state risk; transactional lifecycle follows once verification is strong enough to decide whether resume/commit succeeded.


## N. Antagonist review remediation mapping

This revision explicitly closes the first AnyModel antagonist review blockers:

| Finding | Architectural closure |
| --- | --- |
| Lifecycle/locking underspecified | Versioned coordinator-to-manager interface; existing Security V2 lock order is mandatory; direct concurrent mutation forbidden |
| Crash consistency gap | Durable transaction journal binds operation id, manager generations, commit evidence and effective runtime reconciliation |
| Resume idempotence vague | Per-step idempotence classes, pre/postconditions, retry keys, ambiguous-timeout rules and manual-recovery state |
| Digest != trust | Registry/repository allowlist, platform manifest digest, signer/attestation policy, executed-image binding |
| Secret redaction too narrow | Explicit no-persist/no-log/no-argv/no-env/no-journal/no-traceback contract |
| Verify semantics weak | Capability-restricted adapters, deterministic aggregation, freshness/timeouts, required UNKNOWN => nonzero |
| Rollback races | Ownership fingerprints, generation CAS, lock scope and rollback refusal on concurrent change |
| Release immutability declarative | Immutable evidence binding candidate -> blobs -> artifacts -> image digest -> review/release approval |
| Hidden activation risk | Explicit prohibition plus tests for zero mutation from inspect/preflight/verify paths |

This mapping is evidence for re-review only; it does not itself constitute approval.


## O. Second antagonist review remediation mapping

The second AnyModel antagonist review confirmed the first blocker set closed and identified failure-mode gaps. This revision adds:

| Finding | Architectural closure |
| --- | --- |
| Stale/orphaned lock semantics | Durable holder identity + boot id + fencing generation/token + fail-closed reacquisition |
| Non-V2 mutator ordering | Package/container/systemd/sysctl/certificate mutators serialized behind lifecycle transaction lock |
| Journal corruption/torn writes | Sequence + checksum + canonical serialization + torn/truncated/unknown-schema rejection |
| Rollback image may be pruned | Exact LKG image protected from GC while rollback target; absent LKG => manual recovery |
| Partial cross-manager rollback undefined | Per-manager outcomes + bounded MIXED_GENERATION_MANUAL_RECOVERY state + activation/release block |
| Read-only only test-enforced | Runtime mutation-gate required inside every mutating manager; verify/preflight never receive it |
| Verify policy can be weakened | Verify-policy version/hash bound into release evidence; mismatch => UNKNOWN/nonzero |
| Signing/trust can be downgraded | Release-pinned minimum trust policy, signer rotation/revocation/expiry semantics, node cannot weaken it |

Secret-processing implementations should additionally disable core dumps where supported and avoid swap exposure where platform controls make that practical; this is defense-in-depth and does not replace the no-persist/no-log contract.

This mapping is evidence for re-review only; it does not itself constitute approval.
