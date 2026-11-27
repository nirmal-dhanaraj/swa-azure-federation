#!/bin/bash
# azure/push-to-vm.sh - Run on YOUR WORKSTATION: copy this lab (+ optionally the SWA bundle and conjur CLI) to the Azure VM over SSH.
#   Never copies config.env, .token or state/ (secrets / host-specific). Needs only ssh + tar locally.
# Usage:
#   ./azure/push-to-vm.sh azureuser@<vm-public-ip> [swa-release-v1.2.3.tgz] [path/to/conjur]
#   SSH_OPTS="-i ~/.ssh/azure_vm" REMOTE_DIR=swa-azure-federation/swa-lab ./azure/push-to-vm.sh azureuser@1.2.3.4 ~/Downloads/swa-release-v1.2.3.tgz
set -euo pipefail
TARGET=${1:?usage: $0 user@vm [swa-release.tgz] [conjur-binary]}
BUNDLE=${2:-}; CONJUR=${3:-}
REMOTE_DIR=${REMOTE_DIR:-swa-azure-federation/swa-lab}
SSH_OPTS=${SSH_OPTS:-}
cd "$(dirname "$0")/.."

echo "[1] lab files -> $TARGET:~/$REMOTE_DIR"
tar --exclude=./config.env --exclude=./.token --exclude=./state --exclude=./release --exclude=./.git \
    --exclude=./swa-go-test/swa-go-test --exclude=./image/swa-agent --exclude=./image/swa-go-test -czf - . \
  | ssh $SSH_OPTS "$TARGET" "mkdir -p '$REMOTE_DIR' && tar -xzf - -C '$REMOTE_DIR' && chmod +x '$REMOTE_DIR'/*.sh '$REMOTE_DIR'/azure/*.sh '$REMOTE_DIR'/swa-go-test/build.sh"

if [ -n "$BUNDLE" ]; then
  [ -f "$BUNDLE" ] || { echo "bundle not found: $BUNDLE" >&2; exit 1; }
  echo "[2] SWA bundle $(basename "$BUNDLE") -> ~/$REMOTE_DIR/release/"
  ssh $SSH_OPTS "$TARGET" "mkdir -p '$REMOTE_DIR/release' && tar -xzf - -C '$REMOTE_DIR/release'" < "$BUNDLE"
fi
if [ -n "$CONJUR" ]; then
  [ -f "$CONJUR" ] || { echo "conjur binary not found: $CONJUR" >&2; exit 1; }
  echo "[3] conjur CLI -> ~/$REMOTE_DIR/conjur (install on the VM: sudo install -m 0755 ~/$REMOTE_DIR/conjur /usr/local/bin/conjur)"
  ssh $SSH_OPTS "$TARGET" "cat > '$REMOTE_DIR/conjur' && chmod 0755 '$REMOTE_DIR/conjur'" < "$CONJUR"
fi
echo "Done. On the VM:  cd ~/$REMOTE_DIR && sudo ./azure/vm-bootstrap.sh"
