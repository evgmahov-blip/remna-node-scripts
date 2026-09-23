# Remna Security V2 migration notes

This candidate does not migrate a live node. Do not copy `security/v2` onto a production host as an activation step. Do not set `REMNA_V2_ALLOW_NODE_BASE`. Do not merge this branch to main from this task.

## What an operator still runs

Unchanged:

- `install.sh` / `clean-install.sh` / `full-clean-reinstall.sh` and their pinned blob checks
- NEXT transport profiles and Hysteria2 validation
- `protection-manager.sh` verbs: `install`, `update`, `apply`, `status`, `preflight`, `selftest`, `rollback`, `backend-switch`, manual allow/deny

`protection-manager.sh v2 ...` is an offline helper. It runs before the firewall lock and it refuses `/opt/ainoc` and `/opt/remna-protection`.

## State layout (only under a chosen base)

```text
<base>/settings.conf                         existing inbound settings
<base>/data/                                 existing feeds, lkg, simulator inputs
<base>/v2/policy/features.json               mode 0600, all risky flags default 0
<base>/v2/layers/{inbound,transport,egress}/ current pointer and generations
<base>/v2/egress/secrets/                    WARP material, mode 0600
<base>/v2/detector/facts.json
<base>/v2/transport/decoy.json
```

Tests pass a temporary `--base`. They do not create `/opt/remna-protection`.

## Rollback boundaries

- Inbound rollback restores an inbound generation pointer only.
- Egress rollback restores an egress generation pointer only and must leave inbound set files and WARP last-known-good files in place when those files are not the egress pointer.
- Transport decoy rollback moves the decoy generation counter. The per-node seed stays.
- Existing `protection-manager.sh rollback` is still the inbound firewall snapshot path. V2 does not replace it.

## Enabling anything later

A later reviewed change would have to do all of the following before any node sees new behavior:

1. Keep `FEATURE_AUTO_POLICY` hard-off until that feature has its own review.
2. Turn on WARP only after Phase C selftest and Phase D field notes, still default off in git.
3. Turn on QUIC noise only when WARP is already on. Preflight must keep failing closed on the reverse combination.
4. Admit a fast scanner feed only with a reviewed checksum pipeline. Default catalog entries besides TSPU and GOV stay disabled.
5. Leave nftables cutover off on Docker/UFW nodes.
6. Treat unknown Xray reload methods as a refusal. Do not send `SIGHUP` because it might be ignored.

## Preserved pins

Do not retarget `SOURCE_REF`, Hysteria overlay, V2 cleanup, network manager, or server multitest blob pins while landing V2. Those installers do not call `security/v2`.
