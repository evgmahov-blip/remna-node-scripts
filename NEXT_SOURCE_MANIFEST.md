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
- source commit: `5d022cef3efd046844445c06a1d1ba387359c2c8`
- Git blob SHA: `dbb3a99a9c2a1f442c9e0e19fbebf3ec9d6d871f`

The overlay keeps the recovered NEXT transport logic but fixes the Hysteria2 profile shape to match current Remnawave/Xray behavior:
- server `settings.clients: []`, which Remnawave populates with per-user `auth`;
- `streamSettings.finalmask.quicParams.congestion = brutal`;
- Hysteria transport version 2, TLS, ALPN `h3`;
- a local shape guard rejects a generated Hysteria profile if these fields drift.

The original recovered transport SHA256 remains listed above for provenance; the overlay is intentionally a maintained derivative.
