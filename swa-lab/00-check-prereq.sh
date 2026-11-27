#!/bin/bash
# 00-check-prereq.sh - Check that this host has everything the lab needs. Reports only; never installs anything.
# Exit code: 0 = all required items OK, 1 = something required is missing.
cd "$(dirname "$0")"
[ -f ./config.env ] || { echo "config.env missing -> cp config.env.example config.env and edit it"; exit 1; }
source ./config.env
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'
MISS=0; WARN=0
ok(){   printf "  ${G}OK${N}    %-28s %s\n" "$1" "$2"; }
bad(){  printf "  ${R}MISS${N}  %-28s %s\n" "$1" "$2"; MISS=$((MISS+1)); }
warn(){ printf "  ${Y}WARN${N}  %-28s %s\n" "$1" "$2"; WARN=$((WARN+1)); }
tool(){ # tool <cmd> <install hint>
  if command -v "$1" >/dev/null 2>&1; then ok "$1" "$(command -v "$1")"; else bad "$1" "install: $2"; fi; }

echo "== Config"
if grep -qE '^[A-Z_]+="[^"]*<[a-z-]+>' config.env; then printf "  MISS  %-28s %s\n" "config.env" "placeholders left: $(grep -oE '^[A-Z_]+="[^"]*<[a-z-]+>' config.env | cut -d= -f1 | tr '\n' ' ')"; MISS=1
else printf "  OK    %-28s %s\n" "config.env" "tenant $SWA_API_BASE, domain $BASE_DOMAIN"; fi
for e in $ENVS; do env_load "$e" 2>/dev/null || continue
  [[ $TD =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]] && ok "trust domain $e" "$TD" \
    || bad "trust domain $e" "'$TD' invalid -> fix BASE_DOMAIN / LAB_ID (lowercase letters, digits, . - _)"; done
echo "== Host"
if [ "$(uname -s)" = Darwin ]; then ok "macOS" "$(sw_vers -productVersion) $(uname -m) - Docker Desktop (no root needed)"
else ok "Linux" "$(uname -r) $(uname -m) - user must be able to run docker (root or docker group); k3s runs --privileged"; fi

echo "== Tools"
tool bash      "sudo apt-get install -y bash"
tool curl      "sudo apt-get install -y curl"
tool jq        "sudo apt-get install -y jq"
tool openssl   "sudo apt-get install -y openssl"
tool python3   "sudo apt-get install -y python3   (01-get-token.sh, JWKS build in 10-tenant-setup.sh)"
tool docker    "sudo ./azure/vm-bootstrap.sh (Docker Engine)"
tool kubectl   "sudo ./azure/vm-bootstrap.sh"
tool helm      "sudo ./azure/vm-bootstrap.sh"
docker info >/dev/null 2>&1 && ok "docker engine" "$(docker --version 2>/dev/null)" || bad "docker engine" "docker info failed -> sudo systemctl enable --now docker; if permission denied: log out/in after vm-bootstrap.sh (docker group)"
tool conjur    "Secrets Manager CLI (conjur) from the CyberArk/Idira download page, then: conjur init + conjur login"
for c in sha256sum base64 mktemp sed grep; do tool "$c" "sudo apt-get install -y coreutils grep sed"; done

echo "== SWA release bundle ($SWA_BUNDLE_DIR)"
HINT="mkdir -p $SWA_BUNDLE_DIR && tar -xzf swa-release-v$SWA_VERSION.tgz -C $SWA_BUNDLE_DIR"
# Demo lab: bundle file ownership/permissions and vendor signature (.sig) are intentionally not checked.
if [ -d "$SWA_BUNDLE_DIR" ]; then
  rel=$(awk '/^release:/{print $2}' "$SWA_BUNDLE_DIR/manifest.txt" 2>/dev/null)
  [ "$rel" = "v$SWA_VERSION" ] && ok "bundle release" "$rel (manifest.txt)" || bad "bundle release" "manifest.txt says '${rel:-none}', expected v$SWA_VERSION -> $HINT"
  [ -x "$SWA_AGENT_BIN" ]  && ok "swa-agent binary" "${SWA_AGENT_BIN#$SWA_BUNDLE_DIR/}" || bad "swa-agent binary" "$SWA_AGENT_BIN missing (ls $SWA_BUNDLE_DIR/binaries)"
  [ -f "$SWA_SERVER_TAR" ] && { resolve_server_image; ok "swa-server image tar" "${SWA_SERVER_TAR#$SWA_BUNDLE_DIR/} -> $SWA_SERVER_IMAGE"; } || bad "swa-server image tar" "$SWA_SERVER_TAR missing (ls $SWA_BUNDLE_DIR/container-images)"
else
  bad "bundle directory" "$SWA_BUNDLE_DIR missing -> $HINT"
fi

echo "== Lab inputs"
[ -f swa-go-test/main.go ] && ok "swa-go-test source" "./swa-go-test (main.go, go.mod, go.sum)" || bad "swa-go-test source" "./swa-go-test/main.go missing"
[ -x "$SWA_CLIENT_BIN" ] && ok "swa-go-test binary" "built ($(sha256sum "$SWA_CLIENT_BIN" | cut -c1-12)...)" || warn "swa-go-test binary" "not built yet -> built automatically by 10/30 (needs docker.io/library/golang:1.24)"
[ -f "$SWA_SERVER_CHART" ] && ok "swa-server helm chart" "${SWA_SERVER_CHART#$SWA_BUNDLE_DIR/}" || bad "swa-server helm chart" "$SWA_SERVER_CHART missing"
if command -v docker >/dev/null; then
  if [ "$(docker inspect -f '{{.State.Running}}' "$K3S_NAME" 2>/dev/null)" = true ]; then
    ok "k3s container" "$K3S_NAME running ($(docker inspect -f '{{.Config.Image}}' "$K3S_NAME"))"
    resolve_server_image
    docker exec "$K3S_NAME" crictl inspecti "$SWA_SERVER_IMAGE" >/dev/null 2>&1 && ok "swa-server image (k3s)" "$SWA_SERVER_IMAGE" \
      || warn "swa-server image (k3s)" "not imported yet -> 05-k3s-up.sh imports it from the bundle tar (never pulled)"
  else warn "k3s container" "$K3S_NAME not running -> ./05-k3s-up.sh (pulls $K3S_IMAGE)"; fi
  docker image inspect "$WL_IMAGE" >/dev/null 2>&1 && ok "workload image" "$WL_IMAGE" || warn "workload image" "not built yet -> ./30-build-image.sh (needs docker.io/library/alpine:3.20)"
fi

echo "== Azure VM"
imds=$(curl -s -m 3 -H Metadata:true "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01" 2>/dev/null || true)
if [ -n "$imds" ] && jq -e .vmSize >/dev/null 2>&1 <<<"$imds"; then
  ok "Azure IMDS" "$(jq -r '"\(.name) \(.vmSize) \(.location) \(.storageProfile.imageReference.offer // "") \(.storageProfile.imageReference.sku // "")"' <<<"$imds")"
else warn "Azure IMDS" "not reachable - not an Azure VM? (the lab still works on any Linux Docker host)"; fi
if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = cgroup2fs ]; then ok "cgroup v2" "yes (required by k3s v1.35 kubelet)"
else bad "cgroup v2" "cgroup v1 host - k3s v1.35 kubelet refuses to start -> use Ubuntu 22.04/24.04 (cgroup v2 by default)"; fi
mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
[ "$mem" -ge 3500 ] && ok "memory" "${mem} MiB" || warn "memory" "${mem} MiB - use a VM with >= 4 GiB (e.g. Standard_B2s / B2als_v2)"
dfree=$(df -Pm "$PWD" | awk 'NR==2{print $4}')
[ "${dfree:-0}" -ge 8000 ] && ok "disk free" "${dfree} MiB" || warn "disk free" "${dfree:-?} MiB - images + k3s need ~8 GiB"
if [ "${API_BIND:-}" = "" ]; then warn "API_BIND" "empty = server ports on all interfaces -> keep 18443/18543 closed in the NSG, or set API_BIND=auto"
else ok "API_BIND" "$API_BIND (server ports not published on the VM NIC)"; fi
if command -v docker >/dev/null && docker port "$K3S_NAME" >/dev/null 2>&1; then
  pub=$(docker port "$K3S_NAME" | grep -E '^[0-9]+/tcp -> (0\.0\.0\.0|\[::\]):' | grep -v ':6443' || true)
  [ -z "$pub" ] && ok "k3s port bindings" "$(docker port "$K3S_NAME" | awk '{print $3}' | tr '\n' ' ')" \
    || warn "k3s port bindings" "published on all interfaces: $(echo $pub) -> NSG must block them (or recreate: docker rm -f $K3S_NAME && ./05-k3s-up.sh)"
fi

echo "== Network / firewall"
c=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$SWA_API_BASE/api/info" 2>/dev/null); [[ "$c" =~ ^(200|401)$ ]] \
  && ok "tenant reachable" "$SWA_API_BASE (HTTP $c)" || bad "tenant reachable" "$SWA_API_BASE -> HTTP ${c:-none} (proxy/DNS/firewall?)"
curl -s -o /dev/null -m 10 https://registry-1.docker.io/v2/ && ok "docker.io reachable" "(k3s, busybox, alpine, golang images)" || warn "docker.io reachable" "needed to pull k3s/busybox/alpine/golang images"
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  for i in docker0 podman0; do
    ip link show "$i" >/dev/null 2>&1 || continue
    z=$(firewall-cmd --get-zone-of-interface="$i" 2>/dev/null || echo none)
    case "$z" in trusted|docker) ok "$i firewalld zone" "$z";;
      *) warn "$i firewalld zone" "'$z' - containers may lose egress / host ports; fix: firewall-cmd --permanent --zone=trusted --change-interface=$i && firewall-cmd --reload";; esac
  done
fi
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then   # Ubuntu: UFW drops container -> host ports
  for i in docker0 podman0; do
    ip link show "$i" >/dev/null 2>&1 || continue
    ufw status 2>/dev/null | grep -qE "18443,18543/tcp on $i +ALLOW" && ok "$i ufw" "18443,18543/tcp allowed" \
      || warn "$i ufw" "agents may not reach the servers; fix: ufw allow in on $i to any port 18443,18543 proto tcp"
  done
fi
listening(){ ss -ltnH "sport = :$1" 2>/dev/null | grep -q . || lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
PORTS="$K3S_API_PORT"; for e in $ENVS; do env_load "$e" 2>/dev/null && PORTS+=" $API_PORT"; done
for p in $PORTS; do listening "$p" && warn "port $p" "already in use (ok if $K3S_NAME is running)" ; done

echo "== Credentials"
if command -v conjur >/dev/null && [ ! -s "$HOME/.conjurrc" ]; then warn "conjur init" "~/.conjurrc missing -> conjur init (Secrets Manager SaaS, ${SWA_API_BASE}), then conjur login"
elif command -v conjur >/dev/null; then conjur whoami >/dev/null 2>&1 && ok "conjur login" "$(conjur whoami 2>/dev/null | jq -r .username 2>/dev/null)" || warn "conjur login" "run: conjur login -i <user>  (needed by 10, 40, 99)"; fi
if [ -s "$ADMIN_TOKEN_FILE" ]; then
  c=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H "Authorization: Token token=\"$(tr -d '\n' < "$ADMIN_TOKEN_FILE")\"" -H 'Accept: application/x.secretsmgr.v2+json' "$SWA_API_BASE/api/swa/trust-domains")
  [ "$c" = 200 ] && ok "admin token (.token)" "valid" || warn "admin token (.token)" "HTTP $c -> ./01-get-token.sh"
else warn "admin token (.token)" "missing -> ./01-get-token.sh"; fi

echo
if [ $MISS -gt 0 ]; then echo "${R}$MISS required item(s) missing${N}, $WARN warning(s). Install/fix the MISS items above, then rerun."; exit 1
else echo "${G}All required items OK${N}, $WARN warning(s)."; fi
