# RemnaNode Security — audit, design, handoff

Worktree task `ao-remna-security-20260923`. Base SHA `95787b9204b2213d6490f2f85d5f50f0a35c382d`. No production activation and no live firewall changes are part of this change.

## CURRENT

The protection subsystem that this branch evolves is `protection-manager.sh`, not the recovered NEXT scanner.

Already implemented and kept:

- Owned chains `REMNA_GUARD` and `REMNA_GUARD6` inserted at the front of INPUT. Uninstall and apply delete only those jumps.
- TCP/2222 allow for an explicit `PANEL_IP`, then DROP. Empty or invalid panel IP refuses the change.
- Manual allow and deny files under `/opt/remna-protection/data`.
- TSPU and GOV sets from commit-and-blob pinned snapshots, not from mutable `main`.
- Optional GeoIP allow-list, off by default, all-or-nothing, minimum size check.
- Atomic ipset temp set plus `swap`.
- Last-known-good files when download, digest, or sanity checks fail.
- CIDR sanitation that refuses prefix lengths shorter than /8, which includes `0.0.0.0/0`.
- systemd `remna-protection.service` plus a weekly update timer.
- No `ufw reset`, no flush of INPUT, no deletion of foreign rules.
- TCP-only drops on `FILTER_PORTS`, so UDP/443 Hysteria2 is outside those drops.
- Human menu and the existing CLI verbs used by the legacy Caddy helper.

NEXT installers do not call this module. They still run recovered `next-installer/rkn-watcher-manager.sh` from the byte-for-byte source bundle. That bundle and its SHA pins were not modified. `existing-node-v2-cleanup.sh` is also still pinned and only knows the iptables chain names.

## RKN-WATCHER GOOD PARTS

Taken from the archived Balbuto/RKN-Watcher ideas that this repo already used, and kept:

- Temp set plus atomic swap.
- Last-known-good on failure.
- Whitelist and manual lists.
- Port-scoped filtering instead of dropping every port.
- Optional GeoIP.
- Validation before the live set changes.
- systemd timer and a oneshot restore unit.
- Uninstall of owned objects only.
- Failure paths covered by tests (download, empty, broad, swap failure, rollback).

Not copied: a second product, a separate daemon, or a new default chain name.

## RKN-GUARD GOOD PARTS

Reviewed as an active reference, not as a fork and not as a Go rewrite:

- Separate source classes: slow reviewed government/TSPU data versus faster scanner feeds.
- Counters, a status surface, and explicit ban/unban.
- An update pipeline that validates before replace.
- Honest IPv4 versus IPv6 behavior.
- systemd units, uninstall, and integration-style tests.
- Set-based matching rather than one rule per network.

Not copied: the Go service layout, a new database, a web UI, or live adoption of upstream lists without this repo's pin and sanity rules.

## GAPS (before this change)

- One backend only: iptables/ipset commands inlined in the shell script. No detection of iptables-nft versus legacy versus native nftables.
- No machine JSON. AINOC would have had to scrape the human status.
- No recorded rollback snapshot. Failure kept the previous ipset only when that function returned early.
- Scanner feeds were out of scope; only pinned TSPU/GOV/GeoIP existed.
- Counters, recent errors, and log rate limits were not part of the contract.
- IPv6 was a node-api DROP with no statement that dynamic IPv6 lists do not exist.
- Whitelist and panel safety for external lists was mostly "panel rule is first on 2222". A listed prefix that contained the panel could still drop the panel on `FILTER_PORTS`.

## TARGET ARCHITECTURE

One subsystem, still entered through `protection-manager.sh`:

- Policy in `/opt/remna-protection/settings.conf`.
- Source engine in `security/remna-security.sh` plus `security/remna_sec.py`: download or local fixture, HTML/empty rejection, pin check for https snapshots, CIDR normalization, anomaly check, panel/allow subtraction, staging file, atomic apply, promote to `data/` and `data/lkg/`.
- Firewall plan rendered by Python and applied either to the simulator or, outside this task, to the host.
- Backends: `iptables` (default, including iptables-nft) and `nftables` (owned table only). Detection is reported. Switching is `backend-switch <name> --confirm` after preflight.
- Telemetry: `stats.json`, `recent.json` with a 60-second duplicate suppression, optional limited LOG rules (`LOG_DROPS=0` by default), journald rate limits on the units, logrotate for `/var/log/remna-protection/*.log`.
- JSON schemas `remna-security.{status,preflight,update,selftest}.v1`.
- Human menu kept, including the RKN submenu.

## MIGRATION RISKS

- Native nftables cannot share the filter hook with Docker or UFW without either bypassing them or being bypassed. Preflight refuses nftables in that case. Remna nodes run Docker, so the production-eligible backend remains iptables+ipset until a separate coexistence design is approved.
- `existing-node-v2-cleanup.sh` is pinned and does not delete `inet remna_security`. Do not enable the nftables backend on a node until that cleanup learns the table, or until uninstall of this module has run.
- Legacy install still downloads only `protection-manager.sh` by blob SHA. A future activation must install the `security/` directory as well. This branch does not retarget that installer.
- `BACKEND` defaults to `iptables`, so an in-place migrate does not move an existing node.
- Scanner feeds stay off. Turning them on accepts unpinned https data that still has to pass the sanity pipeline.

## IMPLEMENTATION PLAN (done in this tree)

1. Backend interface and simulator. Live apply stays in the code and exits 2 when `REMNA_SECURITY_FORBID_LIVE=1`.
2. Source pipeline, pinned TSPU/GOV/GeoIP, optional fast scanner.
3. Status counters, recent events, JSON commands.
4. nftables renderer and refusal when Docker or UFW is present.
5. Snapshot rollback, migrate-inplace, and the offline test suite.
6. Review notes below. No Telegram send from this agent; activation stops for a human.

What was not reimplemented: chain names, pin constants, TCP/2222 order, weekly timer, owned-only uninstall, the NEXT source bundle, and the Caddy installer pin.

## Review notes

- nftables `policy accept` on hook input would terminate later filter chains. Refusal beside Docker/UFW is intentional, not a temporary skip.
- External networks that overlap `PANEL_IP` or an allow entry are removed from block sets. Manual deny of the panel IP is rejected.
- Prefix shorter than /8 rejects the whole feed. A poisoned snapshot cannot be partially loaded.
- Tests talk to `REMNA_SECURITY_SIM=1` and a temp base directory. They do not call host iptables, nft, ufw, or systemctl.
- The shell in this session was rejected before the suite could be executed here. CI runs `bash tests/security/run.sh` on pull request.

## IMPLEMENTED

- Unified CLI: previous verbs plus `preflight`, `rollback`, `backend-switch`, `migrate-inplace`, `config-set`, and `--json`.
- Hybrid sources: pinned TSPU, GOV, GeoIP; fast scanners off by default.
- iptables+ipset plan and nftables plan. Default backend unchanged.
- In-place settings migration and deterministic file-level rollback.
- Offline tests for the cases listed in the task, including both backends, Docker/UFW coexistence in the simulator, and JSON schemas.

## TESTS

`bash tests/security/run.sh` with `REMNA_SECURITY_SIM=1` and `REMNA_SECURITY_FORBID_LIVE=1`.

Covered: good update, download failure, HTML, empty, malformed CIDR, `0.0.0.0/0`, prefix shorter than /8, huge and tiny anomaly, atomic swap failure, whitelist collision, panel network in a block feed, duplicate apply, repeated install, uninstall, rollback, selftest restore, IPv4, explicit IPv6 node-api behavior, iptables backend, nftables backend, Docker and UFW coexistence, machine JSON, migrate-inplace, event rate limit, live-apply refusal.

This session could not start a shell, so the suite was not executed here. The workflow step runs it on CI.

## REVIEW FINDINGS

1. Native nftables input hook is unsafe next to Docker or UFW. Resolved by refusing activation; iptables+ipset stays the default.
2. Pinned V2 cleanup does not know the nft table. Resolved by not activating nftables and by documenting the cleanup gap. The pinned script was not edited, because CI checks its blob.
3. A pinned https body was classified as `integrity` before HTML and empty. Resolved by classifying HTML and empty first.
4. Human status used Python f-string backslashes that fail on Python 3.12. Resolved by plain formatting.
5. JSON contract helper word-split the document. Resolved in the test runner.

## RESOLVED FINDINGS

Items 3–5 are code fixes. Items 1–2 are design guards, not follow-up implementation in this branch.

## MIGRATION PLAN

1. Do not run this on a production node in this task.
2. When a later approval says so, install `protection-manager.sh` and `security/` together under the node script directory. Keep `/opt/remna-protection`.
3. Run `migrate-inplace`, then `preflight --json`. Expect `configured_backend=iptables`.
4. Run `selftest --json` and confirm TCP/2222, SSH, and Docker chains.
5. Leave `ENABLE_SCANNERS=0` until a specific https feed is chosen and reviewed.
6. Do not run `backend-switch nftables` on a Docker node. Preflight will refuse it.

## ROLLBACK PLAN

- `protection-manager.sh rollback` restores the newest snapshot under `/opt/remna-protection/rollback` and reapplies the owned ruleset.
- A failed apply does that automatically.
- Uninstall removes owned chains, owned sets, the owned nft table, and the systemd units. It keeps `/opt/remna-protection`.
- Reverting the git tree returns the previous single-file manager. That is a code rollback, separate from the on-node snapshot.

## PROPOSED ACTIVATION

Not proposed for any real RemnaNode.

Stop here for Telegram human approval. No merge to production, no remote firewall change, no nftables cutover, no scanner feed enablement.
