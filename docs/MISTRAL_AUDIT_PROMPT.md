# Mistral audit prompt

You are performing an independent security/reliability audit of the repository:

https://github.com/evgmahov-blip/remna-node-scripts

Audit branch:
audit/mistral-2026-09-24

Baseline production/main commit:
8ce135f1ee01b61a10b1bdf95bfa35ed7ea54ad3

Read first:
1. README.md
2. docs/AUDIT_MISTRAL_2026-09-24.md
3. .github/workflows/ci.yml
4. full-clean-reinstall.sh
5. install.sh
6. clean-install.sh

Then inspect all relevant implementation and tests, especially:
- protection-manager.sh
- security/remna-security.sh
- security/remna_sec.py
- security/v2/**
- next-installer/existing-node-v2-cleanup.sh
- next-installer/remnawave-transport-manager.sh
- next-installer/network-tuning-manager.sh
- next-installer/telemt-manager.sh
- next-installer/telemt-legacy-rkn-adapter.sh
- next-installer/legacy-rebuild-manager.sh
- next-installer/server-multitest.sh
- tests/security/**
- tests/telemt/**

Goal:
Find real security, reliability, destructive-migration, supply-chain, secret-handling, firewall, idempotency, rollback and test-quality defects in the CURRENT implementation.

Important rules:
- Do not trust README or AUDIT_MISTRAL_2026-09-24.md as proof. Verify claims in code.
- Do not assume green CI means the design is safe.
- Do not review open PRs #26/#35/#36 as current behavior. They are not merged into main.
- Do not recommend a new orchestrator or a full rewrite unless a concrete blocker makes the existing design unsalvageable.
- Prefer minimal, reviewable fixes compatible with the existing REMNANODE NEXT architecture.
- Treat generated Hysteria2 config as different from live UDP/443 activation; do not claim runtime activation without evidence.
- Treat destructive migration paths as high-risk.
- Pay special attention to mismatch between shell state, filesystem state, systemd state, Docker state and firewall state.
- Check IPv4 AND IPv6 behavior.
- Check failure ordering and partial-run resume behavior.
- Check whether secrets can leak through argv, env, logs, temporary files, backups or command output.
- Check whether remote downloads are truly pinned and integrity-verified all the way through the bootstrap/overlay chain.
- Check whether UFW and direct iptables/nftables usage can diverge.
- Check whether TCP/2222 can become reachable outside PANEL_IP after any install/update/rebuild path.
- Check whether Telemt Panel/API can become externally reachable.
- Check whether repeated or concurrent runs create duplicate rules, stale state, destructive cleanup or race conditions.
- Check tests for false positives caused by string assertions, simulations, mocked state or missing live-equivalent coverage.

For each finding output:
1. ID
2. Severity: CRITICAL / HIGH / MEDIUM / LOW / INFO
3. File + function/line
4. Evidence from code
5. Concrete failure/exploit scenario
6. Reachability in current main
7. Minimal safe fix
8. Regression test to add

Prioritize findings by exploitability/destructive impact, not style.

After findings, produce these exact sections:

## BLOCKERS BEFORE NEXT RELEASE
Only issues that should block another release or mass rollout.

## SAFE TO DEFER
Real issues that do not need to block the next release.

## TEST GAPS
Missing tests, especially where current CI could pass despite unsafe runtime behavior.

## SUPPLY-CHAIN RISKS
Pinning, remote downloads, immutable refs, checksums, bootstrap/overlay trust.

## MIGRATION / ROLLBACK RISKS
Backup completeness, destructive ordering, resume/retry safety and restore viability.

## CONTRADICTIONS
Any place where README/docs/tests claim behavior that the implementation does not actually guarantee.

## OVERALL RELEASE READINESS
Use one of:
- READY
- READY WITH NON-BLOCKING FIXES
- NOT READY

Explain the choice in 3-8 concise bullets.

Do not praise the project. Be adversarial, specific and evidence-driven.
