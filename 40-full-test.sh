#!/bin/bash
# 40-full-test.sh - Allow/deny matrix for SWA -> Azure federation (needs 10-azure-setup.sh for prod AND dev).
source "$(dirname "$0")/lib.sh"
PASS=0; TOTAL=0
res(){ # res <name> <expected OK|DENY> <actual OK|DENY> <detail>
  TOTAL=$((TOTAL+1)); local c=$R r=FAIL; [ "$2" = "$3" ] && { c=$G; r=PASS; PASS=$((PASS+1)); }
  printf '  %s%-4s%s %-58s expect %-4s got %-4s %s\n' "$c" "$r" "$N" "$1" "$2" "$3" "$4"; }
token_for(){ # token_for <jwt> <env-of-identity> -> sets TOK (empty on failure) and ERR
  local cid tid; az_env "$2"; cid=$CLIENT_ID; tid=$TENANT_ID; az_env "$CUR_ENV"
  TOK=""; ERR=""; [ -n "$1" ] || { ERR="no JWT"; return; }
  exchange "$1" "$cid" "$tid"
  if [ "$HTTP" = 200 ]; then TOK=$(jq -r .access_token <<<"$BODY"); else ERR=$(jq -r '.error_description // .error' <<<"$BODY" | grep -o 'AADSTS[0-9]*' | head -1); ERR=${ERR:-HTTP $HTTP}; fi
}
kv(){ curl -sS -m 20 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" "https://$KV_NAME.vault.azure.net/secrets/$2?api-version=7.4" || echo 000; }
okdeny(){ [ "$1" = "$2" ] && echo OK || echo DENY; }

for e in prod dev; do az_env $e; need_state; done
declare -A JWT
for e in prod dev; do az_env $e; JWT[$e]=$(fetch_jwt "$AZ_AUDIENCE"); done

for e in prod dev; do
  o=$([ $e = prod ] && echo dev || echo prod); CUR_ENV=$e; az_env $e
  echo "${B}== $ENV ($WL, $MI)${N}"
  token_for "${JWT[$e]}" $e; T=$TOK
  res "$e JWT -> $e identity: Entra token"            OK   "$([ -n "$T" ] && echo OK || echo DENY)" "$ERR"
  res "$e token -> Key Vault secret swa-$e-demo"      OK   "$(okdeny "$(kv "$T" "swa-$e-demo")" 200)" ""
  res "$e token -> Key Vault secret swa-$o-demo"      DENY "$(okdeny "$(kv "$T" "swa-$o-demo")" 200)" "(403 expected)"
  token_for "${JWT[$e]}" $o
  res "$e JWT -> $o identity (other subject/issuer)"  DENY "$([ -n "$TOK" ] && echo OK || echo DENY)" "$ERR"
  token_for "$(fetch_jwt conjur)" $e
  res "$e JWT with aud=conjur -> $e identity"         DENY "$([ -n "$TOK" ] && echo OK || echo DENY)" "$ERR"
  J=$(fetch_jwt "$AZ_AUDIENCE" root)
  res "$WL as root asks agent for a JWT-SVID"         DENY "$([ -n "$J" ] && echo OK || echo DENY)" "(node group policy: user)"
done
echo; [ $PASS = $TOTAL ] && echo "${G}$PASS/$TOTAL PASS${N}" || { echo "${R}$PASS/$TOTAL PASS${N}"; exit 1; }
