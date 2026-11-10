# Recovered REMNANODE NEXT source snapshot

Source: known-good running node snapshot supplied 2026-09-19.
The recovered archive is stored byte-for-byte. It includes the working node docker-compose.yml and nginx.conf only as provenance/reference. The installer never copies those two files from the bundle. Secrets, .env and certificates are not included.

Bundle:
- source commit: `721269e2c48e31b7cac86e04bc14c46b33e31e72`
- Git blob SHA: `51a91d5745d0bea9b03eefeeaac52677fcf56b60`
- path: `vendor/remna-next-source.tar.gz`

The bundle itself is verified by immutable commit + Git blob SHA. Individual recovered scripts are additionally verified by SHA256 below.

Files inside bundle:
728ed22841a1c494a9d9fce026109f6151fe16a2b861496d267005bd4850477c  next-installer/setup_node-legacy.sh
620797d0677d091d6550894e32fea58ce7f2adf2f125d6f6ccfb217a7b3382fd  next-installer/next-runtime-guards.sh
441c82fb0eb3b155986d7b84bd66aa82bb1d028b8a9c49e02f1fbac326fac2e2  next-installer/remnawave-transport-manager.sh
2d5838809881a00cac755b43606d7c929e7ba8f5786f64ebff849eb73edeb3e7  next-installer/rkn-watcher-manager.sh
b783e94f2ef3764b2e397cba9eb96aeab88d7da11da017a2c867054f9546a84a  next-installer/selfsteal-site-manager.sh
dbbd1110aec2e6dd32aee204b6d0174d7fe511e1b97118570cbbea553946bd4a  next-installer/xhttp-signature-manager.sh

The bundle is the recovered NEXT source of truth. The old Caddy manager remains in this repository only for legacy-node compatibility and MUST NOT be used by install.sh / clean-install.sh / full-clean-reinstall.sh.


## Hysteria2 compatibility overlay

The recovered archive above remains byte-for-byte unchanged.

A corrected transport manager is stored as:

`next-installer/remnawave-transport-manager.sh`

Pinned overlay:
- source commit: `89c977baa162c11e6316a0c750c7cdbd5c0b551f`
- Git blob SHA: `ee7f33ab33363e09421688d152e73065320d67c1`

The overlay keeps the recovered NEXT transport logic but normalizes Hysteria2 for current Remnawave/Xray and the supplied known-working inbound:
- server `settings.clients: []`, populated by Remnawave with per-user `auth`;
- no legacy `settings.users`;
- sniffing enabled for `http,tls,quic` with `routeOnly=true`;
- Hysteria transport version 2 with `udpIdleTimeout=60`;
- TLS `1.2..1.3`, ALPN `h3`, SNI validation and session resumption;
- no forced server-side `finalmask`;
- no embedded `masquerade` page;
- a local shape guard rejects drift before profile installation.

The original recovered transport SHA256 remains listed above for provenance; the overlay is intentionally a maintained derivative.

## 7-Nov NEXT source continuation (2026-11-08)

Status: **source candidate only; not release-ready**.
Trusted project base: `4f54c59a543abebb58b8bcf7102e77e9931a25fb`.
This isolated editor cycle copied only the eleven requested UTF-8 source files
from `/opt/ainoc-project-worktrees/remna-node-scripts/tg-f20788ec1ff4`.
The supplied provenance identifies candidate
`6620941e7041b6fbba9eb4ac263642d57919f5fa`; the editor did not read Git
internals to attest that worktree's HEAD. Original root `tg-f20788ec1ff4`
and review-paused child `aor-recovery-e57960e4fd81b1cad05dd495f7b103f8`
were neither rerun nor modified. No bytecode/cache files were transferred.

Preserved hardening includes bounded strict-UTF-8 feed validation, rejection
of unsafe candidates without stale-staging promotion, per-feed LKG, private
fsynced atomic publication, scoped nginx cleanup, validated rebuild launcher,
mandatory current protection, stop-before-firewall cleanup, FILTER_PORTS
validation and staged fail-closed iptables reconstruction. Atomic replacements
are per file, not a transaction across live/LKG or all feeds. A directory-fsync
error after rename can leave the complete new file visible.

R4 correction: `update_list_file` now uses existing `atomic_write_text` instead
of direct `write_text` followed by chmod. Regression injects a partial write
for both allow.txt and deny.txt, for add and remove, verifies old bytes and
0600 mode survive, no temporary files remain, and successful retries publish
complete canonical lists with 0600 mode.

### PR #40 and cleanup dependency

Read-only GitHub API inspection on 2026-11-08 returned PR #40 open,
`merged=false`, `mergeable=false`, head
`6058f4016b7b2ed28f1f8bdcf07f522fb56bb732`, base
`8ce135f1ee01b61a10b1bdf95bfa35ed7ea54ad3`.
No conflict resolution or merge is claimed.
GitHub file API resolved cleanup at
`cc375ea8182c76929d9fc1046217ee769a5152d9` to blob
`e4aa53eb348d907b72e6e847a384fabea3399cfb`.
This confirms current availability, not a guarantee of future retention.
AOR must land cleanup through normal review or publish/retain it in the new
source chain before relying on that dependency. Do not merge #40 implicitly
or import its stale Security pins over the 7-Nov hardening.

### Required native AOR continuation

1. Preserve and commit this source candidate on this task's isolated branch;
   publish Security shell/Python, rebuild and cleanup sources first. Obtain
   the actual immutable source commit from AOR. Do not invent a commit SHA,
   use a blob ID as a ref, mutate old tasks, or weaken the drift gates to make
   this intermediate candidate green.
2. Continue this new task from that exact AOR checkpoint. AOR must verify the
   reachable source commit and blob IDs for protection-manager.sh,
   security/remna-security.sh, security/remna_sec.py,
   next-installer/telemt-manager.sh,
   next-installer/telemt-legacy-rkn-adapter.sh,
   next-installer/legacy-rebuild-manager.sh and cleanup. Set MGMT_OVERLAY_REF,
   V2_CLEANUP_REF and their blob constants to those verified sources; update
   cleanup CI assertions consistently. Preserve unchanged networking pins.
3. AOR commits/publishes the resulting full-clean-reinstall.sh manager.
   Continue from that real manager commit to repin both install.sh and
   clean-install.sh, and update README entry URLs using the same immutable
   manager ref. Verify the referenced manager blob equals reviewed HEAD.
4. Run the full final workflow with Git-backed pin checks on the published
   integration SHA. Request independent native AOR review of that exact SHA;
   address findings through normal revise/CI. No merge, release or activation.

Current management and launcher pins still reference earlier code and MUST
NOT be used to deploy this candidate. CI checks management and launcher blobs
against both their pinned source commits and reviewed HEAD, including the
Telemt legacy adapter. Stale pins fail closed. Their expected failure is an
outstanding dependency gate, not a passing final workflow.

### Inherited local validation from reviewed predecessor

2026-11-08: Security PASS 18; V2 PASS 23; feed safety PASS 7; health PASS 4;
Telemt static checks PASS; Mistral F-01..F-06 PASS. bash -n and ShellCheck
0.9.0 `-S error` PASS for all 19 repository shell files. ShellCheck was
extracted from a downloaded Debian package under /tmp without installation.
Workflow YAML and explicit Bash syntax PASS; all six standalone workflow
steps without Git/dependency installation/test runners PASS. Test runners
were executed separately. Git-containing steps and hosted CI were not run
by this editor; final immutable-pin validation remains mandatory in AOR.
Tests used offline simulation. Python bytecode generation was disabled for
imports; the suite explicitly invokes py_compile, so its generated .pyc and
empty __pycache__ directory were removed after validation.

No native AOR dispatcher/review tool is exposed in this editor session.
The ordered continuation above is the request to the owning orchestrator,
not a claim that a review has been scheduled or completed. No commits,
main writes, production changes, SSH/Panel/DNS/firewall operations, ACL,
budget, approval or TaskStore changes were performed. The October AINOC
adapter remains outside this installer gate.

## Immutable-source successor checkpoint (2026-11-08)

Task: `remnanode-next-source-checkpoint-20261108`, revision 0.
Trusted managed-editor base: `4f54c59a543abebb58b8bcf7102e77e9931a25fb`.
Reviewed predecessor supplied by the operator:
`662693e6b638e460945095fa1482fc72f7aeef8c`, task
`remnanode-next-nov7-final-integration-20261108`, HUMAN_APPROVED APPROVE
Opus. Its terminal `candidate_pr_push_rejected` outcome remains immutable;
this successor does not reset or retry that task. The reported publication
failure was an HTTPS origin without credentials.

This editor copied exactly the eleven authorized source text files from
`/opt/ainoc-project-worktrees/remna-node-scripts/remnanode-next-nov7-final-integration-20261108`.
All eleven matched that directory byte-for-byte immediately after copying;
only this manifest subsequently gains successor provenance and evidence.
No cache or bytecode was copied. Git execution and Git internals are blocked
in this editor, so predecessor commit association and the clean base rely on
the trusted handoff, not an independently inspected Git HEAD. AOR must attest
the exact diff and candidate commit before independent native review.

### PR #40 compatibility and source dependency

The PR status and refs above are inherited read-only evidence from the
reviewed predecessor, not a fresh remote inspection by this editor. No direct
SSH/API calls or merge were made. Local verification computed the Git blob
hash from cleanup source bytes (without Git internals):
`e4aa53eb348d907b72e6e847a384fabea3399cfb`, matching the manager's
V2_CLEANUP_BLOB_SHA. Its V2 POSTCHECK and scoped-firewall safety markers and
V2_ASSUME_YES invocation remain compatible; stop-before-firewall ordering
passes the Mistral regression. This establishes local code compatibility,
not remote commit reachability or a resolution of PR #40's merge conflict.
The recorded cleanup ref `cc375ea8182c76929d9fc1046217ee769a5152d9`
remains a publication dependency until AOR verifies reachability or publishes
this cleanup in the new source branch. PR #40 has NOT landed.

### Publication and final release gate

1. AOR creates and publishes the exact reviewed source branch/commit first;
   record its real commit SHA and verify each source blob at that ref.
2. In the next stage, update manager content pins to those published sources,
   with consistent CI assertions. This source stage leaves the reviewed
   manager/launcher pins unchanged and stale; it does not invent immutable
   commit IDs or replace them with blob hashes.
3. Publish the manager and obtain its real immutable commit SHA.
4. Then update launcher and README pins to the published manager; run the
   staged final CI including all Git-backed source/HEAD drift assertions.
   Final CI must be green before release. Stale-pin failures must not be
   bypassed or represented as passing CI.

The native orchestrator owns committing and independent review of the exact
new commit. Neither operation is available through this editor's exposed
tools. No merge, release, production activation, live systemd/DNS/firewall,
other-task mutation, TaskStore/approval/budget/ACL edits, or October AINOC
adapter integration is part of this checkpoint.

### Successor local validation evidence

2026-11-08, this worktree: `bash tests/security/run.sh` exited 0
(Security PASS 18, v2 unittest PASS 23); feed-safety unittest PASS 7,
including interrupted allow/deny add/remove; health unittest PASS 4;
Telemt static checks PASS; Mistral F-01..F-06 PASS. All 19 shell files pass
`bash -n`; workflow YAML parses and every run block passes Bash syntax.
Six standalone workflow guards pass: working-node topology provenance,
NEXT transport architecture, README architecture, legacy safety,
supply-chain/secret guards, and invisible-character guard.

Security tests used simulation and REMNA_SECURITY_FORBID_LIVE=1; the live
apply refusal check passed. PYTHONDONTWRITEBYTECODE=1 was set for imports,
and explicit py_compile output was redirected by PYTHONPYCACHEPREFIX to
`/tmp/remna-source-checkpoint-pycache`. No source-tree __pycache__ or .pyc
exists after validation. Ten transferred files remain byte-identical to the
reviewed predecessor directory; only this manifest adds checkpoint notes.
ShellCheck is unavailable in this editor and was not rerun; its predecessor
result above is historical evidence only. Git-backed workflow checks and
hosted final CI were not run. Current Security shell/Python and rebuild blob
hashes differ from unchanged manager pins, confirming the outstanding
fail-closed dependency gate. This local test result does not certify final
CI or release readiness. Native AOR commit, source publication, and exact-SHA
independent review remain required.


## FINAL INTEGRATION reconciliation (2026-11-10)

The earlier source-only status, stale-pin warnings and ordered publication
instructions above describe checkpoint history only. They do not describe
the restored final integration files. This appended reconciliation preserves
that history and records the concrete current pin evidence for AOR review.

Owner-supplied published provenance:
- PR #53, branch `agent/remnanode-next-final-integration-20261109`, source
  commit `3c68dc4ac0193ee3ba90ef7d2c683ef05974a75d`, tree
  `77d5f3a18527d1c6ca11bc7f06b571b7a26749fa`.
- Manager PR #51: `7bc92b2d78ab01eb608825ad0d44716f5c21a759`.
- Launcher PR #52: `7cd40779d9a1ca994eafd6b8cff450a3be34b975`.
- Clean transfer `952a325dd093b3b32291aee83d760670b5bda5b9` was independently
  verified by AOR to have the identical source tree (owner-supplied evidence).

The actual source scope is 14 changed files relative to base
`4f54c59a543abebb58b8bcf7102e77e9931a25fb`, including this manifest.
All 14 postimages were copied from preserved
`/opt/ainoc-project-worktrees/remna-node-scripts/remnanode-next-clean-transfer-20261110`
and verified byte-for-byte against both that directory and preserved
`/opt/ainoc-project-worktrees/remna-node-scripts/remnanode-next-final-integration-20261109`.
Only this manifest then received this appended section; all implementation
bytes remain identical. The source-postimage blob IDs below are calculated
from accessible bytes using SHA1(`blob <byte-length>\0` + bytes), without
reading Git internals. The manifest row describes its pre-append source blob.

| Source path | Source-postimage Git blob ID |
| --- | --- |
| `.github/workflows/ci.yml` | `bfe9bbd741c17501c08541f568cd83a37a383298` |
| `NEXT_SOURCE_MANIFEST.md` | `b751305dfc0fa7299fdb71515423f60b0b0d0f9f` |
| `PROTECTION.md` | `d46b144e6566e64d139c3764df08d52867a90dc4` |
| `README.md` | `4556bb947b311d92a5a629101015c5b48e073995` |
| `clean-install.sh` | `77ea9f8ad890b3c1058af397fa5261ed2ba6e7aa` |
| `full-clean-reinstall.sh` | `55dfabb44dc615ce5c76f83827c297cc46d5b861` |
| `install.sh` | `5ce63bff3a6281b80a633607c3716c6b552547e1` |
| `next-installer/existing-node-v2-cleanup.sh` | `e4aa53eb348d907b72e6e847a384fabea3399cfb` |
| `next-installer/legacy-rebuild-manager.sh` | `17a57dae41410aff2d9ce8d908636237ea1d6ade` |
| `security/remna-security.sh` | `383cfbaa7d423e519b6ea82057056305b75dd66a` |
| `security/remna_sec.py` | `901d3357e421bf248269dce383226e5ba74f060a` |
| `tests/mistral-blockers/run.sh` | `778c0b3aea663f5371be85851f57fdb7b5df5b11` |
| `tests/security/run.sh` | `6a0e4a9f36cb2f676e86509d024cb761bf7ab9d7` |
| `tests/security/test_feed_safety.py` | `2c609121b1e288a67e0ab8ea50057783a13b25a6` |

Current `full-clean-reinstall.sh` sets both `MGMT_OVERLAY_REF` and
`V2_CLEANUP_REF` to `08249dd53aff595fc12aae273cf128434bc7ed13`.
Its six management blob constants match the accessible current source bytes:

| Constant | Verified current Git blob ID |
| --- | --- |
| `PROTECTION_BLOB_SHA` | `d38486200c4399ec3150e0c3185d7f5620a3606a` |
| `SECURITY_SH_BLOB_SHA` | `383cfbaa7d423e519b6ea82057056305b75dd66a` |
| `SECURITY_PY_BLOB_SHA` | `901d3357e421bf248269dce383226e5ba74f060a` |
| `TELEMT_BLOB_SHA` | `81dcf46d8cff45a681c0808c2ed309053e6edec6` |
| `TELEMT_LEGACY_BLOB_SHA` | `4d75a0ce34ff615fb7006a4e89a2cb619850c9ab` |
| `REBUILD_BLOB_SHA` | `17a57dae41410aff2d9ce8d908636237ea1d6ade` |

`V2_CLEANUP_BLOB_SHA=e4aa53eb348d907b72e6e847a384fabea3399cfb` also
matches the current cleanup bytes. Both `install.sh` and `clean-install.sh`
set `PINNED_REF=7bc92b2d78ab01eb608825ad0d44716f5c21a759` and
`EXPECTED_BLOB_SHA=55dfabb44dc615ce5c76f83827c297cc46d5b861`; the latter
is the computed blob ID of current `full-clean-reinstall.sh`. README's two
entry URLs point to PR #52 SHA
`7cd40779d9a1ca994eafd6b8cff450a3be34b975` for these launchers.

Git execution is denied in this managed editor. Commit/tree associations and
publication provenance above come from the owner handoff; calculated blob
IDs establish local byte consistency, not remote reachability. AOR must
independently verify the published refs and exact new commit. No final
hosted CI or Git-backed workflow success is claimed here.

CI YAML was reviewed as data, parsed successfully, and all run blocks passed
Bash syntax checks. Its source/HEAD drift gates remain byte-for-byte intact;
it contains neither `continue-on-error` nor `|| true`. No bypass or security
weakening was introduced. In particular, the V2 guard retains its historical
`cc375ea8182c76929d9fc1046217ee769a5152d9` blob assertion as well as the
current manager cleanup pin; AOR must check reachability rather than infer
pin status from checkpoint prose.

Local validation on 2026-11-10: Security PASS 18 plus V2 PASS 23; feed
safety PASS 7; health PASS 4; Telemt static security checks PASS; Mistral
F-01..F-06 PASS; all 19 repository shell files pass `bash -n`. Six standalone
workflow guards passed: working-node topology provenance, NEXT transport
architecture, README architecture, legacy safety, supply-chain/secret and
invisible-character guards. Security ran in simulation with
`REMNA_SECURITY_FORBID_LIVE=1`; the live-apply refusal test passed. Imports
used `PYTHONDONTWRITEBYTECODE=1`, with explicit compilation redirected by
`PYTHONPYCACHEPREFIX` outside the repository. No repository bytecode/cache
was created. ShellCheck and Git-backed workflow steps were not run here.

Final comparison covered all 73 accessible source snapshot files: only this
manifest differs from the preserved final integration snapshot. No live
nodes, firewall, DNS, systemd, production, AOR core/TaskStore, or PR #40/#49
were changed. The orchestrator owns the genuinely new manifest commit,
independent Opus review, GitHub CI, gates and Git-release if valid; this
editor neither commits nor claims those downstream operations completed.
