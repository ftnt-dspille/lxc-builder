#!/usr/bin/env bash
#
# Repeatable Rocky Linux LXC fleet builder for Fabric Studio.
#
# Builds one key-only-auth LXC zip per requested point release. The base image
# is fetched at the Rocky major (linuxcontainers only ships majors) and pinned
# to the exact minor via `dnf --releasever distro-sync` (see build-lxc.sh).
#
# Password auth is intentionally DISABLED (key only) until we confirm the
# FS-compatible password-injection build options — pass only --ssh-key-file,
# no --ssh-password / --root-password, and build-lxc.sh sets
# `PasswordAuthentication no` + `PermitRootLogin no`.
#
# Output: ./out/LXC_rockylinux_<minor>_toolbox_amd64.zip  (one per minor)
# Upload + deploy to a pod is handled separately by the FS deploy driver.
#
# Usage:
#   ./build-rocky-fleet.sh                  # builds 9.6 and 9.7 (defaults)
#   RELEASES="9.6 9.7 9.5" ./build-rocky-fleet.sh
#   SSH_USER=fabric SSH_KEY_FILE=keys/fsh-lxc.pub ./build-rocky-fleet.sh
set -euo pipefail
cd "$(dirname "$0")"

RELEASES="${RELEASES:-9.6 9.7}"
DIST="${DIST:-rockylinux}"
MAJOR="${MAJOR:-9}"
ARCH="${ARCH:-amd64}"
VARIANT="${VARIANT:-default}"
SSH_USER="${SSH_USER:-fabric}"
SSH_KEY_FILE="${SSH_KEY_FILE:-keys/fsh-lxc.pub}"
# Lab networks sit behind an SSL-inspecting proxy; disable dnf cert checks so
# the minor-pin/package steps work. Set INSECURE_TLS=0 on a trusted network.
export INSECURE_TLS="${INSECURE_TLS:-1}"

if [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "❌ SSH public key not found: $SSH_KEY_FILE" >&2
    echo "   Generate one: ssh-keygen -t ed25519 -f keys/fsh-lxc -N '' -C fsh-lxc-build" >&2
    exit 1
fi

first=1
for minor in $RELEASES; do
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  Building $DIST $minor (base $MAJOR, $ARCH/$VARIANT, key-only auth)"
    echo "════════════════════════════════════════════════════════════════"
    # Rebuild the Docker image only once; reuse it for the rest.
    nobuild=()
    [[ $first -eq 0 ]] && nobuild=(--no-build)
    ./build-lxc-wrapper.sh \
        "${nobuild[@]}" \
        --releasever "$minor" \
        --ssh-user "$SSH_USER" \
        --ssh-key-file "$SSH_KEY_FILE" \
        "$DIST" "$MAJOR" "$ARCH" "$VARIANT"
    first=0
done

echo ""
echo "✅ Fleet build complete. Artifacts:"
ls -la out/LXC_${DIST}_*_toolbox_${ARCH}.zip 2>/dev/null || true
