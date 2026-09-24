# Telemt + Telemt Panel on RemnaNode

Status: integration branch only. This document does **not** authorize production activation.

## Goal

Run MTProto alongside the existing RemnaWave/Xray/Hysteria2 node without taking TCP/443, UDP/443, TCP/2222, changing Docker rules, or giving the web panel root privileges.

## Security model

- Telemt defaults to TCP/8443. Ports below 1024 are rejected by the manager.
- TCP/80 and TCP/443 are explicitly forbidden by the integration manager.
- Telemt API listens only on `127.0.0.1:9091`.
- Telemt Panel listens only on `127.0.0.1:8080`.
- The subscription listener is disabled.
- Telemt runs as the dedicated `telemt` user.
- Telemt Panel runs as the dedicated `telemt-panel` user.
- Both systemd units have an empty capability bounding set and `NoNewPrivileges=true`.
- Telemt uses tracked conntrack mode and does not install notrack/firewall rules.
- Panel host control is `service_manager = "none"`; privileged operations are `manual`.
- With the current protection stack, the module enrolls the Telemt public port through `protection-manager.sh`. On legacy nodes it uses the reviewed compatibility adapter to extend the existing `REMNA_RKN_SCANNERS` guard and add the matching UFW admission; it does not create a second firewall contour.

This intentionally gives up Telemt's notrack optimization in exchange for isolation from the node firewall.

### Fake-TLS / SNI policy

For production RemnaNode installs, prefer **self-mask**: `TLS_DOMAIN` should be a real hostname owned by the operator, resolving to the same node and presenting a valid certificate on the node's ordinary HTTPS service. Using the node hostname keeps TCP/443 and Telemt TCP/8443 consistent under active TLS probing.

Avoid unrelated third-party SNI values (for example public CDN domains) as a default. They can create an unnecessary cross-port fingerprint even when Fake-TLS itself is valid.

Changing `TLS_DOMAIN` changes the generated `ee` MTProxy secret/link. Regenerate/distribute the link after a mask-domain change.

## Pinned upstreams

- Telemt: `3.5.7`
- Telemt Panel: `v1.0.0-rc.2` (prerelease)

Release assets are verified against hard-coded SHA256 values before installation. Updating either version requires updating and reviewing the hashes in `next-installer/telemt-manager.sh`.

## Commands

```bash
sudo next-installer/telemt-manager.sh preflight

# Prefer self-mask: use the same real hostname that already resolves to the node
# and has a valid TLS certificate on the node's normal HTTPS endpoint.
sudo env \
  TLS_DOMAIN=sui2.remna.2rdp.ru \
  PANEL_PASSWORD='<strong one-time password>' \
  TELEMT_PORT=8443 \
  next-installer/telemt-manager.sh install

sudo next-installer/telemt-manager.sh status
sudo next-installer/telemt-manager.sh disable
sudo next-installer/telemt-manager.sh uninstall
```

The uninstall command removes units and binaries but preserves configuration and data for rollback/recovery.

## Admin access

The panel is intentionally not public. Use an SSH tunnel:

```bash
ssh -L 8080:127.0.0.1:8080 root@NODE
```

Then open `http://127.0.0.1:8080` locally.

A future public admin endpoint must be a separate reviewed change (preferably mTLS or another independently authenticated management network). Do not expose port 8080 directly.

## Firewall ownership

The current node protection ownership remains authoritative. New protection-manager nodes append the public port (default `8443`) to `FILTER_PORTS`. Legacy RKN nodes use `telemt-legacy-rkn-adapter.sh`, which backs up and extends the existing persistent scanner guard to `80,443,8443` and adds only the corresponding UFW admission.

The default RemnaNode security profile is **semi-paranoid**: TSPU and GOV feeds enabled, dynamic scanner blocking enabled with validated last-known-good fallback, GeoIP allow-list disabled, and drop logging disabled. Thus TCP/8443 receives the same scanner/source filtering as the normal public TCP service ports without turning the node into a geographic allow-list.

## Production gate

Before first live activation:

1. Run `preflight` on a clean test node.
2. Verify existing listeners on TCP/443, UDP/443 and TCP/2222 are unchanged.
3. Verify `127.0.0.1:8080` and `127.0.0.1:9091` are not externally reachable.
4. Verify Telemt's TCP/8443 works from an external Telegram client.
5. Run current RemnaNode transport and protection self-tests.
6. Stop Telemt and verify RemnaWave/Hysteria2 remain healthy.
7. Restart Telemt and verify no firewall rules changed.
8. Only then consider a separate production activation decision.
