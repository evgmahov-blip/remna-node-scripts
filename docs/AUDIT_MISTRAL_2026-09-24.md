# Mistral Audit Handoff — 2026-09-24

## Audit target

Repository: evgmahov-blip/remna-node-scripts

Production/main baseline:
- main SHA: 8ce135f1ee01b61a10b1bdf95bfa35ed7ea54ad3
- audit-prep branch: audit/mistral-2026-09-24
- audit-prep branch differs from main only by documentation/CI documentation guards
- latest main CI after PR #37 merge: success

Audit the implementation, not this document. Treat this file as orientation only.

## Current architecture

REMNANODE NEXT is the primary installer and management surface.

Core chain:
1. install.sh / clean-install.sh
2. pinned full-clean-reinstall.sh launcher
3. immutable recovered NEXT bootstrap bundle
4. pinned overlays for transport, cleanup, network tuning, tests, security, Telemt and rebuild management
5. runtime installation into /opt/remnanode and /usr/local/libexec

Important modules:
- full-clean-reinstall.sh
- install.sh
- clean-install.sh
- protection-manager.sh
- security/remna-security.sh
- security/remna_sec.py
- next-installer/existing-node-v2-cleanup.sh
- next-installer/remnawave-transport-manager.sh
- next-installer/network-tuning-manager.sh
- next-installer/telemt-manager.sh
- next-installer/telemt-legacy-rkn-adapter.sh
- next-installer/legacy-rebuild-manager.sh
- next-installer/server-multitest.sh

## Security / trust boundaries

Expected invariants:
- no global firewall flush/reset in destructive migration paths;
- TCP/2222 must remain restricted to PANEL_IP;
- Telemt public port is TCP/8443;
- Telemt Panel stays on 127.0.0.1:8080;
- Telemt API stays on 127.0.0.1:9091;
- Telemt and Panel run as dedicated unprivileged users with hardened systemd units;
- unrelated containers/services should survive managed legacy rebuild;
- legacy node-agent and stale legacy nginx/UFW state should be removable addressably;
- node secrets must never be printed;
- recovery backup must happen before destructive cleanup;
- rebuild must be resumable and idempotent enough to survive interruption;
- external source downloads are expected to be immutable/pinned and integrity-checked;
- scanner feed validation must fail safe on malformed content without rejecting valid mixed-family feeds;
- live protection status must reflect actual firewall state, not only stored state.

## Current protection profile

Default semi-paranoid profile:
- TSPU: enabled
- GOV: enabled
- scanner feed: enabled
- GeoIP allow-list: disabled
- drop logging: disabled
- protected service ports include 443 and 8443
- Node API TCP/2222 must be panel-IP restricted

## Live validation evidence

Live validation host used during implementation:
- ger3.remna.2rdp.ru
- public IP: 77.90.33.118
- panel IP: 213.108.130.95

Validated:
- legacy node cleanup and rebuild completed;
- remnanode and remnawave-nginx active;
- unrelated Beszel container preserved;
- legacy remnawave-node-agent removed;
- stale 2443/4443 listeners/rules removed;
- XHTTP TCP/443 reachable;
- Node API TCP/2222 protected by panel-IP rule;
- Telemt TCP/8443 reachable;
- Telemt Panel/API loopback-only;
- Telemt Fake-TLS uses ger3.remna.2rdp.ru;
- real Telegram client MTProto end-to-end traffic confirmed with successful Telegram DC RPC handshakes;
- security feed loaded TSPU, GOV and scanner sets;
- hostname/node identity refreshed from legacy wlplay identity to ger3.

Important limitation:
- generated Hysteria2 profile exists, but actual UDP/443 runtime depends on the Remnawave panel applying that profile. Do not treat generated config alone as proof that Hysteria2 is live.

## Areas that deserve aggressive review

1. Supply-chain / pinning
   - whether all remote downloads are actually immutable and verified;
   - whether old pinned bootstrap commits can become an unexpected trust anchor;
   - whether overlay pin chains can drift or create circular/stale dependencies.

2. Destructive migration safety
   - backup completeness and restore usefulness;
   - failure ordering;
   - resume behavior after partial cleanup or partial install;
   - accidental deletion of unrelated Docker/systemd/nginx/UFW state.

3. Firewall correctness
   - rule ordering;
   - IPv4/IPv6 divergence;
   - UFW + direct iptables coexistence;
   - Node API bypass possibilities;
   - stale rule accumulation;
   - scanner list failure modes and rollback.

4. Secret handling
   - shell tracing / process list / temp files;
   - compose/env parsing;
   - backup archives;
   - file permissions;
   - accidental output in logs.

5. Telemt isolation
   - service hardening;
   - bind addresses;
   - capability bounds;
   - filesystem write scope;
   - interaction with firewall/protection-manager;
   - upgrade/reinstall behavior.

6. Shell robustness
   - set -Eeuo pipefail interactions;
   - local variable initialization;
   - stdin/TTY behavior;
   - quoting;
   - command substitution;
   - interrupted runs and traps.

7. Idempotency / concurrency
   - simultaneous installer runs;
   - apt/dpkg locks;
   - systemd reload/restart races;
   - duplicate firewall rules;
   - repeated rebuild/resume invocations.

8. Test quality
   - gaps between simulated tests and live behavior;
   - assertions that can pass while runtime is unsafe;
   - missing negative tests;
   - CI assumptions tied to exact strings instead of behavior.

## Open GitHub context

Open PRs #26, #35 and #36 are not part of current main.
Do not use them as evidence of current behavior unless explicitly comparing future/unmerged work.
#35 and #36 contain UI/health-center work that may require rebasing after the Telemt/security merge.

## Expected audit output

For every finding provide:
- severity: CRITICAL / HIGH / MEDIUM / LOW / INFO;
- exact file and line/function;
- concrete evidence;
- failure or exploit scenario;
- whether it is reachable in current main;
- minimal safe fix;
- regression test that should be added.

Finish with:
- BLOCKERS BEFORE NEXT RELEASE
- SAFE TO DEFER
- TEST GAPS
- SUPPLY-CHAIN RISKS
- MIGRATION/ROLLBACK RISKS
- OVERALL RELEASE READINESS

Do not give a generic architecture rewrite. Prefer minimal changes compatible with the existing NEXT design.
