#!/bin/bash
# install-docker.sh -- provision script for LXC image build.
# Installs Docker CE on RHEL-family (Rocky/Alma/CentOS 9) inside the build chroot.
set -eu

echo "[install-docker] detecting package manager ..."
if command -v dnf >/dev/null 2>&1; then
    PKG_MGR=dnf
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR=yum
else
    echo "[install-docker] ERROR: no dnf/yum found" >&2
    exit 1
fi

echo "[install-docker] installing dnf-plugins-core ..."
$PKG_MGR install -y -q dnf-plugins-core

echo "[install-docker] adding docker-ce repo ..."
$PKG_MGR config-manager -y --add-repo https://download.docker.com/linux/centos/docker-ce.repo

echo "[install-docker] installing docker-ce ..."
$PKG_MGR install -y -q \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-compose-plugin \
    docker-buildx-plugin

echo "[install-docker] enabling docker.service ..."
systemctl enable docker.service 2>/dev/null || true

# Docker-in-LXC: overlayfs/overlay2 can't handle whiteout files inside an LXC
# container (kernel limitation). Force the vfs storage driver so image layers
# extract cleanly. Without this, pulling/loading images fails with:
#   "failed to convert whiteout file ...: operation not supported"
mkdir -p /etc/docker
echo '{"storage-driver":"vfs"}' > /etc/docker/daemon.json

DOCKER_VERSION=$(docker --version 2>/dev/null || echo "unknown")
echo "[install-docker] baked: $DOCKER_VERSION"
