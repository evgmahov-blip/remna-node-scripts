# Native AOR NEXT migration contract (candidate)

This is a new SWE operation. It neither restores CAN tasks nor changes GER5/PL/CAN.
`next-installer/aor_onboarding.py` is a stateless offline adapter library, not a
remote executor, dispatcher, approval service, provisioning system or TaskStore.
It is not yet wired to a native AOR execution capability. No rollout has occurred.
The evidence validator checks supplied records; it cannot authenticate attestations
or prove that their assertions are true. Native AOR must verify those separately.

## Entry and continuation

AOR dispatches and supervises this operation using its existing task/effect store.
Bind every record to task_id, operation_id and exact release commit. Evidence uses
schema `remna.aor-evidence.v1`, with `stages` keyed by the ordered STAGES constants.
Each stage contains aor_attestation_ref, effect_id, observed_at, artifact_sha256 and
boolean checks. Keep raw evidence root-only, outside ordinary logs. Run:

```sh
python3 next-installer/aor_onboarding.py /private/evidence.json \
  --task TASK --operation OPERATION --release EXACT_COMMIT
```

Exit 3 identifies the first unproved stage, 2 rejects invalid input, 0 means only
that supplied evidence is ready for native verification. It is never permission
for execution. There is no automatic production command in this adapter.

## PRECHECK / BACKUP_RESTORE_PROOF

Use only sanctioned AOR remote execution. Reconcile Inventory, approved Cloudflare
origin and server identity with `origin`; public DNS alone proves no origin.
The preliminary 2.27.14.107 observation is not an approved target. Record provider,
credential entitlement and protected source reference without values. Establish a
working management and independent recovery channel. Inventory Docker/systemd
3x-ui, all listeners (including IPv6), 80/443 owners, dependencies, active sessions
and users. Never stop 3x-ui here. V2 cleaner and clean-install.sh are forbidden.

Native AOR must obtain a provider-consistent read-only snapshot of the full
application/dependency closure. `recovery` archives explicitly inventoried paths
from that snapshot, refuses live writable sources, checks SQLite integrity and
reads the archive back. A WAL-bearing DB is rejected: obtain a provider-approved
consolidated snapshot/SQLite online-backup copy without stopping live 3x-ui.
This helper does not acquire snapshots or prove application consistency.

Required root-only bundle inventory: SQLite DB, inbound/client metadata,
/etc/x-ui or Docker bind mounts/named volumes and compose/environment files,
TLS/ACME and renew hooks, reverse proxy configuration, SSH configuration and
recovery authorization, firewall/ipset/IPv4/IPv6 rules, routes/rules, all old
container inspect/image digests and units/drop-ins, DNS records and panel host
memberships. Inventory each dependency and mark absent components explicitly.
Capture remote command output privately, not in AOR/public logs. The output
parent must be root-owned mode 0700; archive is exclusively created mode 0600.
Store returned SHA256 in native evidence. Preserve snapshot IDs and retention.

Restore proof requires an isolated restore rehearsal: validate checksum, restore
DB/config/volumes and old image digests, verify users/inbounds and TLS, boot old
units with isolated networking and test old service. Archive readability alone
is NOT restore proof. Keep a reviewed ordered restore plan and tested recovery
access in the bundle. No automatic archive extraction on the live host.

## Stage, review, owner gate, controlled cutover

Stage the exact reviewed NEXT release without running it on the live server.
Reuse full-clean-reinstall.sh and its immutable source checks; do not fork the
installer or weaken existing pins. NEXT_SOURCE_MANIFEST.md already documents
source-publication prerequisites: unresolved pins block release. CI and independent
review must refer to that exact release. Native AOR must verify a separate explicit
owner approval bound to release, target, operation, rollback and cutover window.

Only after that gate, stop the inventoried 3x-ui unit/container, retain it and all
volumes, verify TCP/443 is released, then invoke the existing NEXT setup path under
AOR supervision. Do not use global uninstall, ufw reset, Docker prune or SSH edits.
Record each effect and postcondition in AOR. Failure stops forward progress and
invokes the reviewed rollback through the same sanctioned executor.

## Registration and verification

Pilot desired identity: SWE-NEXT, swe.remna.2rdp.ru:2222, countryCode SE;
profile SWE-NEXT-XHTTP with inbound swe-xHTTP; Host `🇸🇪 Швеция`, address
swe.remna.2rdp.ru, REALITY XHTTP TCP/443, full matching xHTTP extra,
securityLayer DEFAULT, Xray template default, mapper empty and flow empty.
Generate unique path/keys using existing NEXT generators and shared SECRET_KEY
from the approved protected source. Do not put keys into operation logs.

Use existing approved Cloudflare integration only after authoritative origin
proof. Native AOR must list objects before creation and serialize per operation;
`reconcile` returns reuse for exact effects and rejects duplicate/drift matches.
It is not a distributed lock and must not be used as one.
Fetch ALL pages of GET /internal-squads immediately before reconciliation.
`squad_changes` constructs additive inbound patches, excludes users and requires
Host ALLOW_ONLY UUIDs exactly equal to the full squad set. Use panel's existing
API adapter to apply patches with concurrency protection. Refetch and run
`verify_squads`; membership races require fresh reconciliation, never deletion.

Require two host-network containers, nginx unix socket SelfSteal, xHTTP signature,
correct active/local profile, REMNA_GUARD ipset feeds (TSPU/GOV/scanners), panel-only
2222 IPv4/IPv6, BBR/fq, NOFILE >=65536, systemd health, certbot.timer/deploy hook
and successful renewal dry-run. Prove panel isConnected=true, external TCP/443,
TLS and real external client traffic. Recheck every internal squad and Host set.

Rollback: stop only new NEXT managed units/containers; restore old 3x-ui config,
DB, volumes, units and image digests from verified recovery; restore only scoped
changed firewall/DNS/panel effects using preimages and concurrent-change checks;
restart old service and verify client traffic, users, TLS and management access.
Never delete shared panel entities or other nodes. Keep rollback available after
successful cutover per owner-approved retention.

## Current handoff / blockers

Local editor scope has no native dispatcher/Inventory/Cloudflare/remote executor
capability. PRECHECK is pending; origin, SSH reachability, provider, credentials,
3x-ui topology and active users remain unverified. No production approval exists
in this operation. Dispatcher continuation: attach sanctioned remote executor and
approved integrations to this SAME task, collect PRECHECK evidence, then follow
the ordered stages. Missing access is ACCESS/PROVIDER/EXECUTOR, unknown origin is
IDENTITY/DNS; do not create AOR repair tasks or alternate executors. Owner must
make the production gate decision only after review, CI and rollback proof.

Statuses: code candidate; independent review pending; CI remote pending; release,
installation and runtime verification pending. Do not report rollout complete.
