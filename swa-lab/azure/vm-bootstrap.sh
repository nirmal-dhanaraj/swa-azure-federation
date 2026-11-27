#!/bin/bash
# azure/vm-bootstrap.sh - Prepare an EXISTING Azure Ubuntu VM (22.04 / 24.04, x64 or Arm64) for the SWA lab.
#   Installs: Docker Engine (docker-ce repo), kubectl, helm, jq, curl, openssl, python3, git.
#   Adds the invoking user to the "docker" group, loads k3s kernel modules, opens UFW for docker0 -> server ports.
#   Does NOT install the conjur CLI or the SWA bundle (both come from the CyberArk / Idira download portal).
# Usage:  sudo ./azure/vm-bootstrap.sh          (idempotent; safe to rerun)
#   KUBECTL_VERSION=v1.35.0 HELM_VERSION=v3.19.0 sudo -E ./azure/vm-bootstrap.sh   to pin other versions
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }
. /etc/os-release
[ "${ID:-}" = ubuntu ] || echo "WARN: tested on Ubuntu 22.04/24.04, this is ${PRETTY_NAME:-unknown}"
KUBECTL_VERSION=${KUBECTL_VERSION:-v1.35.0}   # match the k3s minor (config.env K3S_IMAGE v1.35.x)
HELM_VERSION=${HELM_VERSION:-v3.19.0}
LAB_USER=${SUDO_USER:-$(logname 2>/dev/null || echo root)}
ARCH=$(dpkg --print-architecture)              # amd64 | arm64
export DEBIAN_FRONTEND=noninteractive

echo "[1] base packages"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg jq openssl python3 git tar coreutils iproute2 >/dev/null

echo "[2] Docker Engine"
if ! command -v docker >/dev/null || ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null
fi
systemctl enable --now docker >/dev/null
echo "    $(docker --version)"

echo "[3] kubectl $KUBECTL_VERSION"
if ! kubectl version --client 2>/dev/null | grep -q "${KUBECTL_VERSION}"; then
  curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl"
  chmod 0755 /usr/local/bin/kubectl
fi
echo "    $(kubectl version --client 2>/dev/null | head -1)"

echo "[4] helm $HELM_VERSION"
if ! helm version --short 2>/dev/null | grep -q "^${HELM_VERSION}"; then
  t=$(mktemp -d); curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz" | tar -xz -C "$t"
  install -m 0755 "$t/linux-$ARCH/helm" /usr/local/bin/helm; rm -rf "$t"
fi
echo "    helm $(helm version --short)"

echo "[5] docker group for $LAB_USER"
if [ "$LAB_USER" != root ] && ! id -nG "$LAB_USER" | grep -qw docker; then
  usermod -aG docker "$LAB_USER"; echo "    added -> log out and back in (or: newgrp docker) before running the lab scripts"
else echo "    ok"; fi

echo "[6] kernel modules for k3s-in-docker"
for m in overlay br_netfilter; do modprobe "$m" 2>/dev/null || true; done
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/swa-k3s.conf

echo "[7] host firewall (UFW) - containers must reach the server ports on docker0"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow in on docker0 to any port 18443,18543 proto tcp >/dev/null && echo "    ufw: allowed 18443,18543/tcp on docker0"
else echo "    ufw inactive - nothing to do (Azure NSG still controls inbound from the network)"; fi

echo
echo "Done. Next (as $LAB_USER, after re-login):"
echo "  1. install the conjur CLI:  sudo install -m 0755 conjur /usr/local/bin/conjur"
echo "  2. extract the bundle:      mkdir -p release && tar -xzf swa-release-v1.2.3.tgz -C release"
echo "  3. cp config.env.example config.env && vi config.env && ./00-check-prereq.sh"
