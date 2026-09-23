# Remna Security V2 candidate status

Base expected: `32ad1743c7b27b91cb6ad0997100b358917cde4a`. Architecture reviewed: `6876cc4902187f4ef610ad96c85fc21e356d937d`. No activation, no merge, no live firewall change.

## Implemented

- Architecture note: `docs/REMNA_SECURITY_V2_ARCHITECTURE.md`
- Machine-readable JSON Schemas in `security/v2/schemas/` and validators in `security/v2/contracts.py`
- Positive and negative fixtures in `tests/security/v2/fixtures/`
- Detector queue: 60s dedup, TTL, 24h retention, bounded queue, overflow event, no mutations
- Pure policy evaluation and a mutating path that refuses, including when `FEATURE_AUTO_POLICY` is configured to 1
- Feature file `<base>/v2/policy/features.json` (mode 0600). Defaults off. QUIC-without-WARP fails preflight and is not rewritten into a corrected config. Effective auto-policy, fast scanners, decoy runtime, node plugin, and nftables cutover stay 0
- Per-layer generations, shared transaction id, independent rollback, retention of current plus five previous, documented lock order
- Temp write, file fsync, rename, parent fsync; degraded fsync is labeled `degraded`
- WARP key model, X25519, registration parser and retry rules, lifecycle metadata, selftest-before-LKG, orphan-risk cleanup
- Endpoint parser (IPv4, bracketed IPv6, name), trust order, health promotion/demotion/cooldown/reboot
- QUIC v1 Initial (RFC 9000/9001 key schedule and header protection), versioned profile `chrome-like-h3-v1`, content hash
- Offline Xray outbound shape: wireguard `dialerProxy` -> freedom `rand` + base64 Initial. Activation plan/result stay inactive. Unknown reload and `SIGHUP` refuse
- Scanner category catalog and preset names. Admission of TSPU/GOV goes through existing `validate_feed`. Fast categories return `fast_feed_disabled`
- Decoy seed plus status/rotate/rollback. External assets off
- Node-plugin contract that rejects authoritative ingress
- CLI `protection-manager.sh v2` dispatched before the firewall lock
- Tests wired at the end of `tests/security/run.sh`

## Deferred

- Phase C runtime preflight/selftest against a real rw-core and a real WARP registration
- Phase D lab matrix (broadband, mobile, CGNAT, IPv4-only, dual-stack, constrained MTU/loss)
- Phase E production decision
- Live Xray temp-file, `run -test`, rename, reload, and end-to-end verification
- Full self-steal HTML renderer. Next step is in `security/v2/decoy.py`: render from the stable seed, keep remote assets off, do not write inbound rules
- Enabling any mutable scanner feed
- nftables cutover and Docker/UFW coexistence design
- Automatic policy actions
- Fetching WARP from Cloudflare during CI
- Public probe targets. The health module takes an injected classifier so tests stay offline

## Test evidence

Command:

```bash
bash tests/security/run.sh
```

That script still runs the existing simulator suite, then `tests/security/v2/run.sh` (`python3 -m unittest discover`). New cases cover schema fixtures, AES/GCM and X25519 vectors, RFC 9001 Initial keys, 100 QUIC packets with decrypt/parse and byte diversity, secret mode 0600 and redaction, registration retry classes, endpoint families and trust, last-known-good on failed selftest, detector TTL/dedup/overflow, flag dependency failure, three-plane rollback isolation, crash-safe pointer behavior, degraded fsync, Xray outbound shape, profile hash, scanner pipeline, decoy seed stability, and the absence of a global firewall flush in `security/v2`.

Coordinator validation of `bash tests/security/v2/run.sh` and `bash tests/security/run.sh` is pending until after the RFC 9001 Appendix A.1 `client_initial_secret` expected-vector correction. Do not treat this candidate as PASS until that rerun. Existing transport pin checks in `.github/workflows/ci.yml` are unchanged.

## Not done

No node was contacted. No firewall was changed. No WARP account was registered. No Xray process was started. No merge was created.
