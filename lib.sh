#!/bin/bash
# lib.sh - shared helpers. Sourced by every script.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
HERE=$PWD
[ -f config.env ] || { echo "config.env missing -> cp config.env.example config.env and edit it" >&2; exit 1; }
source ./config.env

B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'
die(){ echo "${R}ERROR: $*${N}" >&2; exit 1; }
ok(){ echo "  ${G}OK${N}   $*"; }
miss(){ echo "  ${R}MISS${N} $*"; }
warn(){ echo "  ${Y}WARN${N} $*"; }
b64d(){ local s; s=$(tr '_-' '/+'); while (( ${#s} % 4 )); do s+='='; done; base64 -d <<<"$s" 2>/dev/null; }
jwt_payload(){ local p; IFS=. read -r _ p _ <<<"$1"; b64d <<<"$p"; }
jwt_header(){ local h; IFS=. read -r h _ _ <<<"$1"; b64d <<<"$h"; }

# Load the SWA lab settings (trust domain, SPIFFE ID, workload container names) without changing our cwd.
[ -f "$LAB_DIR/config.env" ] || die "SWA lab not found: $LAB_DIR/config.env (set LAB_DIR in config.env)"
pushd "$LAB_DIR" >/dev/null; source ./config.env; popd >/dev/null
source ./config.env   # source ours again so our values (e.g. ENVS) win over the lab's
mkdir -p state && chmod 700 state

# az_env <prod|dev>: lab names (env_load from the lab) + Azure names for this environment
az_env(){
  env_load "$1"                         # TD, NG, WL, SID, AUTHN ... from the lab
  MI="id-swa-$ENV${LAB_ID:+-$LAB_ID}"   # user-assigned managed identity
  FIC="fic-swa-$ENV"                    # federated identity credential on that identity
  KV_SECRET="swa-$ENV-demo"             # Key Vault secret this environment may read
  AST="state/$ENV"; mkdir -p "$AST"
  # Client id / tenant id: from config.env (Portal route) or written by 10-azure-setup.sh (CLI route)
  local v="${ENV^^}_CLIENT_ID"; CLIENT_ID=${!v:-}; TENANT_ID=${AZ_TENANT_ID:-}
  [ -n "$CLIENT_ID" ] || CLIENT_ID=$(cat "$AST/client_id" 2>/dev/null || true)
  [ -n "$TENANT_ID" ] || TENANT_ID=$(cat "$AST/tenant_id" 2>/dev/null || true)
}

# fetch_jwt <aud> [user]: ask the agent inside the workload container for a JWT-SVID; prints the JWT or nothing.
# Uses the swa-agent CLI, allowed by node group policy element 2 of the lab (unix.path == /opt/swa/bin/swa-agent).
fetch_jwt(){
  local aud=$1 user=${2:-$SA_USER} out
  out=$(docker exec --user "$user" "$WL" /opt/swa/bin/swa-agent api fetch jwt -a "$aud" -s /run/swa-agent/api.sock --output json 2>&1 || true)
  jq -r '..|strings|select(startswith("eyJ"))' <<<"$out" 2>/dev/null | head -1 || true
  [ -n "${DEBUG:-}" ] && echo "$out" >&2 || true
}

# exchange <jwt> <client-id> <tenant-id>: JWT-SVID -> Entra access token (client credentials + client assertion).
# Sets HTTP and BODY.
exchange(){
  local f; f=$(mktemp)
  HTTP=$(curl -sS -m 30 -o "$f" -w '%{http_code}' -X POST "$AZ_LOGIN_HOST/$3/oauth2/v2.0/token" \
    --data-urlencode "client_id=$2" \
    --data-urlencode "scope=$AZ_SCOPE" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=$1") || HTTP=000
  BODY=$(cat "$f"); rm -f "$f"
}

need_state(){ [ -n "$CLIENT_ID" ] && [ -n "$TENANT_ID" ] || die "no Azure identity for $ENV yet: set AZ_TENANT_ID and ${ENV^^}_CLIENT_ID in config.env (Portal) or run ./10-azure-setup.sh $ENV (CLI)"; }
