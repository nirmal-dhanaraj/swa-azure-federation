#!/bin/bash
# 00-check-prereq.sh - Check tools, Azure login, the SWA lab, and that Entra will be able to verify SWA JWT-SVIDs.
# Reports only, never changes anything. Run on the Azure VM where the SWA lab runs.
source "$(dirname "$0")/lib.sh"
FAIL=0; bad(){ miss "$*"; FAIL=1; }

echo "${B}[1] Tools${N}"
for t in docker jq curl; do
  if command -v $t >/dev/null; then ok "$t"; else
    case $t in az) bad "az  -> curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash";; *) bad "$t -> sudo apt-get install -y $t";; esac
  fi
done

command -v az >/dev/null && ok "az (optional)" || warn "az not installed: fine for the Portal route; needed only for 10-azure-setup.sh / 99-cleanup.sh"

echo "${B}[2] Config${N}"
grep -q '<unique>' <<<"$KV_NAME" && bad "KV_NAME still has <unique> in config.env" || ok "KV_NAME=$KV_NAME"
[[ $KV_NAME =~ ^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$ ]] || bad "KV_NAME must be 3-24 chars, start with a letter, letters/digits/hyphens"

echo "${B}[3] Azure login${N}"
if command -v az >/dev/null && az account show >/dev/null 2>&1; then
  [ -n "$AZ_SUBSCRIPTION" ] && az account set -s "$AZ_SUBSCRIPTION" 2>/dev/null
  ok "subscription: $(az account show --query '[name,id]' -o tsv | paste -sd' ')"
  ok "tenant:       $(az account show --query tenantId -o tsv)"
else warn "az not logged in: fine for the Portal route (needed only for 10-azure-setup.sh)"; fi
for e in $ENVS; do az_env "$e"
  [ -n "$CLIENT_ID" ] && [ -n "$TENANT_ID" ] && ok "$ENV: tenant $TENANT_ID client $CLIENT_ID" \
    || warn "$ENV: no client id / tenant id yet (Portal: set AZ_TENANT_ID, ${ENV^^}_CLIENT_ID in config.env; CLI: ./10-azure-setup.sh $ENV)"
done

for e in $ENVS; do
  az_env "$e"
  echo "${B}[4:$ENV] SWA lab workload $WL${N}"
  if [ "$(docker inspect -f '{{.State.Status}}' "$WL" 2>/dev/null)" = running ]; then ok "$WL running"
  else bad "$WL not running -> cd $LAB_DIR && ./51-lab-start.sh $ENV"; continue; fi

  JWT=$(fetch_jwt "$AZ_AUDIENCE")
  if [ -z "$JWT" ]; then bad "no JWT-SVID with aud=$AZ_AUDIENCE (DEBUG=1 ./00-check-prereq.sh shows the agent error;"
    echo "        policy element 2 'unix.path == /opt/swa/bin/swa-agent' must still be in node group $NG)"; continue; fi
  P=$(jwt_payload "$JWT"); H=$(jwt_header "$JWT")
  ISS=$(jq -r .iss <<<"$P"); SUB=$(jq -r .sub <<<"$P"); ALG=$(jq -r .alg <<<"$H")
  ok "JWT-SVID iss=$ISS"
  ok "         sub=$SUB"
  ok "         aud=$(jq -c .aud <<<"$P") alg=$ALG"
  [ "$SUB" = "$SID" ] || warn "sub differs from the lab's expected SPIFFE ID $SID (the JWT value is used)"
  [ ${#SUB} -le 600 ] || bad "subject longer than 600 chars (Entra limit)"
  [ ${#ISS} -le 600 ] || bad "issuer longer than 600 chars (Entra limit)"

  echo "${B}[5:$ENV] Issuer discovery (Entra fetches these from the Internet)${N}"
  DISC=$(curl -sS -m 15 "$ISS/.well-known/openid-configuration" 2>/dev/null || true)
  if jq -e .jwks_uri >/dev/null 2>&1 <<<"$DISC"; then
    ok "$ISS/.well-known/openid-configuration"
    DISS=$(jq -r .issuer <<<"$DISC"); JU=$(jq -r .jwks_uri <<<"$DISC")
    [ "$DISS" = "$ISS" ] && ok "discovery issuer matches JWT iss" || bad "discovery issuer '$DISS' != JWT iss '$ISS'"
    KID=$(jq -r .kid <<<"$H")
    if curl -sS -m 15 "$JU" | jq -e --arg k "$KID" '.keys[]|select(.kid==$k)' >/dev/null 2>&1; then ok "jwks_uri has kid $KID"
    else warn "kid $KID not (yet) in $JU"; fi
  else
    bad "no OpenID discovery document at $ISS/.well-known/openid-configuration -> Entra cannot validate this issuer"
  fi
  [ "$ALG" = RS256 ] || warn "JWT alg is $ALG. If the exchange fails with an AADSTS signature/algorithm error, this is the cause"
done

echo
[ $FAIL = 0 ] && echo "${G}All required items OK${N}" || { echo "${R}Fix the MISS items and rerun${N}"; exit 1; }
