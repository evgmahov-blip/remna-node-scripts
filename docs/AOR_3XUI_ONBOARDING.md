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
boolean checks. artifact_sha256 must be 64 lowercase hex characters; observed_at
must be an ISO timestamp with timezone; effect_id must be unique across stages.
Keep raw evidence root-only, outside ordinary logs. Run:

```sh
python3 next-installer/aor_onboarding.py continuation /private/evidence.json \
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
It rejects both WAL and rollback-journal sidecars, including databases nested
inside archived directory members. Connections are explicitly closed.

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
Input is the unwrapped complete squad list. Inbounds may be API objects with
`uuid`/`tag`/`profileUuid`; additive PATCH values are inbound UUIDs, not tags.
`info.membersCount` is mandatory and compared before/after; missing counts fail
closed. Equal counts do not prove identical member identities. Native AOR must
serialize the operation and compare a complete private paginated member snapshot
if identity-preservation proof is required; this helper makes no such claim.

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

## Executable target-local operations

These commands are callable by the sanctioned native AOR remote executor; do not
run them via a substitute SSH transport. No command grants production approval.
Use an existing root-owned directory with mode 0700. CLI failures emit a fixed
error, not paths, SQL values, container environment or personal information.

```sh
python3 next-installer/aor_onboarding.py preflight \
  --database /etc/x-ui/x-ui.db --output /private/preflight.json
python3 next-installer/aor_onboarding.py recovery \
  --snapshot /mnt/provider-consistent-readonly --inventory /private/inventory.json \
  --output /private/recovery.tar.gz
python3 next-installer/aor_onboarding.py restore-test \
  --bundle /private/recovery.tar.gz --sha256 BUNDLE_SHA256
python3 next-installer/aor_onboarding.py verify-squads \
  --before /private/squads-before.json --after /private/squads-after.json \
  --host /private/host-policy.json --inbound-uuid PANEL_INBOUND_UUID
```

Preflight collects IPv4/IPv6 listeners and established connections, systemd units
and x-ui dependencies/config, Docker containers/inspect, routes/rules and firewall
backends into one private exclusively-created 0600 artifact. It counts inbounds,
clients and enabled clients from a single read-only SQLite transaction. It does
not copy client records into that artifact. Docker inspect can contain secrets;
the artifact must remain root-only. Missing tools are recorded, not interpreted
as absence. Docker detection uses container names/images; renamed deployments
require Inventory corroboration. Both detected types require resolving ambiguity.
Enabled clients and socket counts are NOT active-user identity proof. App-specific
runtime activity, actual port owners, custom dependencies, management/recovery
access, authorized credential source and origin agreement remain native PRECHECK
requirements. This command always returns pending (exit 3), never auto-passes it.

Recovery inventory JSON has `members` (relative snapshot files/directories),
`databases` (relative SQLite files), and `coverage`. Each coverage key in
`RECOVERY_CATEGORIES` must have `{"paths":["relative/path"]}` referring to
archived data. Only optional TLS/ACME and reverse-proxy categories can instead
have `{"absent_reason":"verified reason"}`. Mandatory categories cannot be
marked absent. Native AOR must review coverage semantics and full dependency
closure; path presence does not establish completeness or snapshot consistency.
An example *shape*, not a valid complete inventory:

```json
{"members":["etc/x-ui"],"databases":["etc/x-ui/x-ui.db"],
 "coverage":{"database":{"paths":["etc/x-ui/x-ui.db"]}}}
```

The bundle embeds `REMNA-RECOVERY.json` containing file SHA256s, original
ownership/modes, explicit category coverage and an ordered restore plan. Nested
symlinks, special files, unsafe paths, invalid DBs and existing output files are
rejected. Recovery automatically rehearses file extraction in a temporary private
directory, checks every file digest and runs SQLite integrity checks, then removes
the rehearsal directory. `restore-test` repeats this against the recorded archive
checksum. It restores bytes for verification, not original permissions/ownership,
service processes or networking. Output explicitly says
`runtime_restore_verified=false`; BACKUP_RESTORE_PROOF still requires the isolated
old-service runtime test, original ownership/mode restoration and recovery-access
attestation by native AOR. No production extraction command is provided.

Host-policy JSON is `{"mode":"ALLOW_ONLY","internalSquads":["squad-uuid"]}`,
normalized by the existing panel adapter. verify-squads validates this set against
the complete fresh after-list as well as checking before/after squad sets,
additive inbounds and unchanged member counts. It prints only counts/booleans.

The immutable launcher pin chain currently requires the main installer blob to
match both launcher source refs. This revision keeps that blob and all pins
unchanged. Integrating a production cutover/setup command requires an exact
reviewed release and orchestrator-owned publication/repinning; invoking the clean
installer against live 3x-ui is not a supported shortcut.

Local validation: onboarding fixtures include successful archive/isolated file
restore, nested DBs, WAL/journal rejection, invalid SQLite, symlink/traversal,
private permissions, checksums, API-shaped squads, CLI redaction and evidence
formats. Fixture tests mock only root ownership/identity and read-only filesystem
flags so they also execute on non-root CI. They do not attest provider snapshots,
real target access, application consistency or runtime recovery.

### Exact native continuation for this pilot

Continue task `remnanode-next-swe-3xui-aor-onboarding-20261117`, revision 1;
do not restore CAN or create a replacement operation. First unfinished stage:
PRECHECK. Classification: EXECUTOR (no sanctioned executor exposed to this
editor), IDENTITY/DNS (origin unproved), ACCESS/PROVIDER (credentials, provider
and recovery channel unproved). The public DNS/SSH observations are historical
observations, not validated access or origin evidence.

Native dispatcher must attach its sanctioned executor and existing approved
Inventory/Cloudflare integrations, bind an operation ID and the eventual exact
reviewed release, then execute the preflight command on the verified target.
Collect entitlement references privately and resolve every missing collector,
active-user observation and dependency before creating the consistent snapshot.
Next: recovery + isolated runtime restore proof -> stage exact NEXT release ->
independent review/required CI -> separate explicit owner production decision.
No such approval is present in this handoff. Cutover/setup integration and
publication remain pending; file-rehearsal success must not advance OWNER_GATE.
After approval use only scoped native effects, then require every VERIFY check,
including isConnected, real external traffic and complete fresh squads/Host sets.
