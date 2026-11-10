# Immutable NEXT preflight for AINOK Stage3.8

This is a **preflight-only**, fail-closed source-project artifact. It does not
complete an install or certify Inventory READY. No trusted external dependency
closure is available in the released source checkpoint
`ee240a73db2481eb3d08d8806866a14d08a10ad6`.

Build locally from this reviewed checkout, without network or Git access:

```sh
python3 -B scripts/build-next-artifact.py /tmp/remna-next-preflight.sh
cd /tmp
sha256sum -c remna-next-preflight.sh.sha256
```

The generator emits a mode-0700 executable shell file, its byte SHA256 sidecar,
and a canonical JSON manifest sidecar. Builds are byte-identical regardless of
output filename, checkout directory, time or umask. Python 3 and a POSIX shell
are preinstalled prerequisites; the artifact never installs them. The manifest
locks original launcher/manager/NEXT script and vendor bytes with SHA256.
The vendor archive is embedded unchanged; every regular member is verified in
memory without extraction. Installed scripts and services are never invoked.
The lock records local bytes associated with the owner-attested source commit;
it is not an independent Git commit/reachability attestation. Review the lock
and generator together. Do not regenerate the lock to suppress drift failures.

Stage the single shell artifact with its **externally verified artifact SHA256**
through the existing Stage3.8 mechanism. A self-contained checksum cannot
authenticate its own verifier; AOR must approve and retain that external SHA.
No AOR core or gate change is required. The generator prints the actual SHA;
no fixed release hash is asserted in this document.

One-command node-side preflight after staging (root, with the credential already
provided on protected stdin by the caller):

```sh
DOMAIN=node.example.com EMAIL=ops@example.com /path/to/verified-artifact.sh
```

Do not put the credential in the command, shell history or an environment
assignment. Stdin must be a pipe supplied by the trusted root caller, or a
root-owned regular file with no group/other permission bits. The artifact
cannot authenticate a pipe's writer; the staging caller owns that boundary.
An inherited `SECRET_KEY` is rejected; the PR968 env bridge is unnecessary here.
No secret is persisted, printed, passed in argv, or sent to a child installer.
The input is one nonempty, whitespace-free byte string (max 4096 bytes), with
an optional trailing newline, followed by EOF. Domain is a dotted DNS name;
email uses a bounded ASCII mailbox syntax. Values are validated but not echoed.
No credential validity against a panel is claimed.

For offline smoke testing use `--dry-run` with synthetic stdin. This mode can
run without root; normal invocation requires root. Both modes always refuse
installation. Exit 3 means `BLOCKED_NOT_AVAILABLE`, exit 2 means rejected input
or source integrity. JSON Lines schema `remnanode.next.artifact.v1` reports
started, sources_verified, inputs_validated and completed events as applicable.
The terminal blocked event includes precise dependency IDs/reasons, `ready:false`
and `writes:false`. The latter means no installation/configuration writes;
the host shell may use temporary storage to implement its embedded heredoc.
Missing shell/Python or a loader failure can occur before JSON is available;
the caller must treat any absent terminal event as failure.

Remaining closure includes apt packages and their transitive authenticated
snapshot, Docker repository key, platform image digests/offline layers, Xray
ZIPs, templates/selfsteal assets and script content. Caddy is excluded, with no
verified key/package closure supplied. A reviewed non-destructive machine
adapter is also absent: existing interactive scripts can store credentials and
change network/firewall state. They are embedded only as verified provenance,
never executed. Optional legacy update/benchmark URLs in those bytes remain
untrusted dependencies, not approved downloads. No mutable source is fetched.
SSH, Telemt, firewall, DNS, Panel and deployed nodes are untouched.

Run the local tests:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/immutable-artifact/test_artifact.py
```

These tests are offline and use synthetic secrets. They do not substitute for
normal independent model review, existing project CI, exact-commit AOR review,
release approval or production activation. Original interactive entrypoints
remain unchanged. A future full install requires reviewed dependency closure
and a safe adapter; this artifact cannot be switched to READY via a flag or
caller-provided dependency manifest.
