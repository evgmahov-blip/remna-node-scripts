# Recovered REMNANODE NEXT source snapshot

Source: known-good running node snapshot supplied 2026-09-19.
Runtime-specific docker-compose.yml, nginx.conf, secrets, certificates and domain data are intentionally NOT vendored.

Bundle:
af02c8733bc03d6b17d93f28fc54d751127a472aec3811a0b725b7a2697f04c9  vendor/remna-next-source.tar.gz

Files inside bundle:
728ed22841a1c494a9d9fce026109f6151fe16a2b861496d267005bd4850477c  next-installer/setup_node-legacy.sh
620797d0677d091d6550894e32fea58ce7f2adf2f125d6f6ccfb217a7b3382fd  next-installer/next-runtime-guards.sh
441c82fb0eb3b155986d7b84bd66aa82bb1d028b8a9c49e02f1fbac326fac2e2  next-installer/remnawave-transport-manager.sh
2d5838809881a00cac755b43606d7c929e7ba8f5786f64ebff849eb73edeb3e7  next-installer/rkn-watcher-manager.sh
b783e94f2ef3764b2e397cba9eb96aeab88d7da11da017a2c867054f9546a84a  next-installer/selfsteal-site-manager.sh
dbbd1110aec2e6dd32aee204b6d0174d7fe511e1b97118570cbbea553946bd4a  next-installer/xhttp-signature-manager.sh

The bundle is the recovered NEXT source of truth. The old Caddy manager remains in this repository only for legacy-node compatibility and MUST NOT be used by install.sh / clean-install.sh / full-clean-reinstall.sh.
