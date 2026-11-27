#!/bin/bash
# 30-read-keyvault.sh <prod|dev> [secret-name] - Use the Azure token from 20-get-azure-token.sh to read a Key Vault secret.
#   SHOW=1  print the value in full (masked by default)
source "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || die "usage: $0 <prod|dev> [secret-name]"
az_env "$1"; NAME=${2:-$KV_SECRET}
get_token(){ local out; out=$(./20-get-azure-token.sh "$ENV" 2>&1) || { echo "$out" | sed -n '/HTTP/,$p'; die "could not get an Azure token for $ENV (see above)"; }; }
EXP=$(jwt_payload "$(cat "$AST/azure_token" 2>/dev/null)" 2>/dev/null | jq -r '.exp // 0' 2>/dev/null || echo 0)
[ "${EXP:-0}" -gt $(( $(date +%s) + 60 )) ] || get_token

URL="https://$KV.vault.azure.net/secrets/$NAME?api-version=7.4"
echo "GET $URL   (as $MI)"
F=$(mktemp); CODE=$(curl -sS -m 20 -o "$F" -w '%{http_code}' -H "Authorization: Bearer $(cat "$AST/azure_token")" "$URL" || echo 000)
BODY=$(cat "$F"); rm -f "$F"
if [ "$CODE" = 200 ]; then
  V=$(jq -r .value <<<"$BODY"); [ "${SHOW:-0}" = 1 ] || V="${V:0:6}****"
  echo "${G}HTTP 200${N} $NAME = $V"
else
  echo "${R}HTTP $CODE${N} $(jq -r '.error.code + ": " + .error.message' <<<"$BODY" 2>/dev/null | cut -c1-200)"
  [ "$CODE" = 403 ] && echo "   403 = the identity has no role on this secret (expected for the other environment's secret;"
  [ "$CODE" = 403 ] && echo "         for its own secret wait a few minutes after 10-azure-setup.sh)"
  exit 1
fi
