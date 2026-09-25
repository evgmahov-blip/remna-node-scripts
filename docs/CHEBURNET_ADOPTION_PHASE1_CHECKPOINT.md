# CheburNET Adoption — Phase 1 Checkpoint

Status: **CONTRACTS / TESTS ONLY**

Parent architecture:
- PR #45
- branch: `arch/cheburnet-adoption`
- architecture SHA: `66e613b1a9ef137f8f9486a4d82d5825534b7289`

Implementation branch:
- `feat/cheburnet-adoption-p1-contracts-r2`
- base: `66e613b1a9ef137f8f9486a4d82d5825534b7289`

## Scope delivered

Phase 1 adds only data contracts and pure/offline validation helpers:

- lifecycle journal contract;
- coordinator-to-manager mutation envelope;
- verify result / fail-closed aggregation contract;
- image provenance + last-known-good rollback identity contract;
- secret-preflight evidence contract;
- release / verify-policy / trust-policy binding contract;
- six JSON schema documents;
- stdlib behavioral tests;
- CI invocation for the Phase 1 tests.

## Explicit non-scope

This branch does **not** wire the contracts into:

- installers or menus;
- firewall / nftables / UFW;
- Security V2 runtime mutation;
- Xray / Remnawave;
- Docker;
- systemd;
- sysctl;
- Telemt;
- certificate issuance;
- panel/API mutation;
- live node activation.

No second firewall owner or security plane is introduced.

Security V2 lock order remains:

`transaction -> inbound -> transport -> egress`

## Fail-closed behaviors covered

The tests require:

- missing/unknown schema versions fail closed;
- corrupt/torn journal records are rejected;
- bad/duplicate journal sequence is rejected;
- invalid idempotence classes are rejected;
- mutation envelopes require a fencing token and canonical Security V2 lock order;
- required `FAIL` is non-success;
- required `UNKNOWN`, malformed or missing required checks are non-success;
- `NOT_CONFIGURED` is accepted only for explicitly optional/unconfigured checks;
- raw secret-looking fields/material are rejected;
- mutable-tag-only image trust is rejected;
- exact platform digest and LKG image identity are required;
- release evidence cannot authorize activation;
- verify/trust policy hash mismatch fails closed;
- the Phase 1 package exposes no runtime capabilities and imports no network/subprocess/runtime-control modules.

## Test command

CI command:

```bash
bash tests/cheburnet_adoption/run.sh
```

The runner sets `PYTHONDONTWRITEBYTECODE=1`, so tests do not create tracked `__pycache__` / `.pyc` artifacts.

Actual pass/fail evidence is the GitHub Actions result for this branch/PR. This document does not claim a PASS before CI reports one.

## Known limitations

Phase 1 intentionally does not:

- execute mutations;
- implement lock acquisition or fencing-token issuance;
- write a transaction journal;
- inspect a running image;
- inspect real Remnawave secret material;
- perform live verification;
- sign or publish release evidence.

Those belong to later phases and remain separately gated.

## Next boundary

Phase 2 may start only after:

1. Phase 1 CI is green;
2. independent review has no blocking findings;
3. the architecture parent remains unchanged or the contracts are re-reviewed against any architecture change.

Phase 2 is still read-only implementation. It must not introduce live mutation or production activation.
