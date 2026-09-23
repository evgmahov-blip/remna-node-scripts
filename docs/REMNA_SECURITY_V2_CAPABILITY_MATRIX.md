# Capability matrix

Current means this repository's inbound security and NEXT transport as already shipped. Reference ideas are integrated only where the row says so. Host firewall ownership stays here.

| Capability | Current remna-node-scripts | Balbuto/RKN-Watcher | Flecksis/rkn-guard | eGamesAPI/remnawave-reverse-proxy @ 7b29ddbe | SolverNA/warp-xray-generator @ dcd99bcc | This V2 candidate |
| --- | --- | --- | --- | --- | --- | --- |
| Owned inbound chains/sets only | Yes | Similar owned ipset | Set-based match | Host firewall stays outside the proxy | No | Preserved |
| Atomic replace + last-known-good | Yes | Yes | Validate before replace | n/a | New WARP gen must selftest before LKG | Preserved inbound; added for egress secrets and layer generations |
| Port-scoped filter, timers | Yes | Yes | Yes | n/a | n/a | Preserved, not re-owned |
| Whitelist / manual lists | Yes | Yes | Ban/unban surface | n/a | n/a | Preserved |
| Slow reviewed vs fast scanner classes | TSPU/GOV pinned; scanners off | Single list style | Explicit classes | Scanner category ideas | n/a | Catalog added; fast feeds still refused |
| IPv4/IPv6 truthfulness | Dynamic IPv6 lists are false | v4-centric | Explicit families | n/a | v4 and v6 endpoint fields | Endpoint parser records ipv4, ipv6, or name; dynamic inbound IPv6 lists stay false |
| Counters / JSON status | Yes | Limited | Yes | n/a | n/a | Preserved inbound JSON; V2 contracts added |
| Tests without live firewall | Yes | Partial | Yes | n/a | Network-heavy upstream | Extended offline |
| Self-steal / decoy mutation | Self-steal site in NEXT | n/a | n/a | Template mutation idea | n/a | Stable seed + rotate/rollback; renderer deferred; trackers off |
| Node plugin | No | n/a | n/a | Optional plugin concept | n/a | Contract only; cannot be authoritative ingress |
| Local WARP registration | No | n/a | n/a | n/a | Yes, plus public subscription architecture | Local client/parser only; no Vercel/Upstash/public subscription |
| X25519 + secret storage | No | n/a | n/a | n/a | Local keys | Local X25519, mode 0600, redacted status |
| Endpoint pool | No | n/a | n/a | n/a | Often one endpoint | configured / lkg / registration / discovered with trust order |
| Health through WARP path | No | n/a | n/a | n/a | Registration-time assumptions | Injected classifier, promotion, demotion, cooldown, reboot unknown |
| QUIC v1 Initial + Xray noises | No | n/a | n/a | n/a | Yes | Reimplemented offline; dialerProxy + freedom noises; not activated |
| Automatic policy | No | n/a | n/a | n/a | n/a | Pure evaluate only; hard-off |
| nftables cutover | Renderer exists; default iptables; refused beside Docker/UFW | n/a | n/a | n/a | n/a | Still refused; flag cannot become effective |
| Live routing / activation | Out of current security task | Live on its own hosts | Live on its own hosts | Proxy deploy | Live Xray config | Not implemented; plan refuses unknown reload and SIGHUP |

Reference repositories were read as ideas. Their public frontends, databases, and deploy paths are not copied.
