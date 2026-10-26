#!/usr/bin/env bash
# One-time SSH enrollment for AINOC. Run locally as root on the new VPS.
set -euo pipefail
export LC_ALL=C
[[ "$(id -u)" == 0 ]] || { echo "Run as root." >&2; exit 1; }
command -v ssh-keygen >/dev/null || { echo "OpenSSH tools are required." >&2; exit 1; }
key_type='ssh-ed25519'
key_blob='AAAAC3NzaC1lZDI1NTE5AAAAIBBxLibq3l1iX/rE1uLsaJHnwSUGfy9VsxO06RKs7mxH'
key_line="from=\"213.108.130.95\" $key_type $key_blob ainoc-control"
ssh_dir=/root/.ssh
auth="$ssh_dir/authorized_keys"
[[ ! -L "$ssh_dir" && ! -L "$auth" ]] || { echo "Symlink SSH path: stopped." >&2; exit 1; }
umask 077
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
if [[ -e "$auth" && ! -f "$auth" ]]; then
  echo "authorized_keys is not a regular file." >&2
  exit 1
fi
if [[ ! -f "$auth" ]] || ! awk -v blob="$key_blob" '{ for (i=1;i<=NF;i++) if ($i==blob) found=1 } END { exit !found }' "$auth"; then
  if [[ -f "$auth" ]]; then
    backup=$(mktemp "$ssh_dir/authorized_keys.before-ainoc.XXXXXXXX")
    cp -p -- "$auth" "$backup"
  fi
  printf '\n%s\n' "$key_line" >> "$auth"
fi
chmod 600 "$auth"
echo "AINOC key is present. SSH configuration and firewall were not changed."
echo "HOST: $(hostname)"
echo "SSH HOST FINGERPRINTS (send these to AINOC):"
found=0
for pub in /etc/ssh/ssh_host_*_key.pub; do
  if [[ -f "$pub" ]]; then
    ssh-keygen -lf "$pub"
    found=1
  fi
done
[[ "$found" == 1 ]] || { echo "No SSH host public keys found; enrollment is not verified." >&2; exit 1; }
echo "Next: verify this fingerprint and check SSH access from AINOC."
