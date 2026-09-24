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
- This module never changes UFW, iptables, nftables, Docker networking, Caddy, RemnaWave, or `REMNA_GUARD*`.

This intentionally gives up Telemt's notrack optimization in exchange for isolation from the node firewall.

## Pinned upstreams

- Telemt: `3.5.7`
- Telemt Panel: `v1.0.0-rc.2` (prerelease)

Release assets are verified against hard-coded SHA256 values before installation. Updating either version requires updating and reviewing the hashes in `next-installer/telemt-manager.sh`.

## Commands

```bash
sudo next-installer/telemt-manager.sh preflight

# Generate the bcrypt hash with a reviewed matching telemt-panel binary first.
sudo env \
  TLS_DOMAIN=example.org \
  PANEL_PASSWORD_HASH='<bcrypt hash>' \
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

The integration does not open TCP/8443 automatically. Production activation must explicitly decide how that port is admitted by the existing node firewall/protection policy. The current `REMNA_GUARD` ownership model remains authoritative.

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
