#!/bin/bash
# 20-get-azure-token.sh <prod|dev> - Step by step: SWA JWT-SVID (aud api://AzureADTokenExchange) -> Entra access token.
#   SHOW_JWT=1   print the raw JWT-SVID and Azure token (both are bearer tokens: do not paste them anywhere)
# The Azure token is cached in state/<env>/azure_token (mode 600, ~1 h) for 30-read-keyvault.sh.
source "$(dirname "$0")/lib.sh"
[ $# = 1 ] || die "usage: $0 <prod|dev>"
az_env "$1"; need_state
TENANT=$TENANT_ID
short(){ [ "${SHOW_JWT:-0}" = 1 ] && echo "$1" || echo "${1:0:30}...${1: -15} (${#1} bytes; SHOW_JWT=1 to print)"; }

echo "${B}1. Workload asks its local SWA agent for a JWT-SVID with the Azure audience${N}"
echo "   \$ docker exec --user $SA_USER $WL swa-agent api fetch jwt -a $AZ_AUDIENCE"
JWT=$(fetch_jwt "$AZ_AUDIENCE"); [ -n "$JWT" ] || die "agent refused (DEBUG=1 for details)"
echo "   JWT-SVID: $(short "$JWT")"
jwt_payload "$JWT" | jq '{iss, sub, aud, exp: (.exp|todate)}' | sed 's/^/   /'
echo "   No secret is used: the agent attested the process (user + binary) and the SWA Server signed the JWT."

echo; echo "${B}2. Workload sends the JWT-SVID to Microsoft Entra as a client assertion${N}"
echo "   POST $AZ_LOGIN_HOST/$TENANT/oauth2/v2.0/token"
echo "        client_id=$CLIENT_ID ($MI)  grant_type=client_credentials  scope=$AZ_SCOPE"
echo "        client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer  client_assertion=<JWT-SVID>"
exchange "$JWT" "$CLIENT_ID" "$TENANT"
if [ "$HTTP" != 200 ]; then
  echo "${R}   HTTP $HTTP${N}"; jq -r '"   " + (.error // "") + ": " + (.error_description // . | tostring | .[0:400])' <<<"$BODY" 2>/dev/null || echo "$BODY"
  echo "   Common causes: AADSTS70021/700213 = no federated credential matches iss/sub/aud (rerun 10, wait a few min);"
  echo "   AADSTS700211 = issuer not trusted; AADSTS50027/700024 = signature/expiry; network = Entra cannot fetch the SWA JWKS."
  exit 1
fi
AT=$(jq -r .access_token <<<"$BODY"); umask 077; printf '%s' "$AT" > "$AST/azure_token"
echo "   ${G}HTTP 200${N} access token: $(short "$AT")"
jwt_payload "$AT" | jq '{aud, iss, appid, oid, xms_mirid, exp: (.exp|todate)}' 2>/dev/null | sed 's/^/   /' || true
echo "   Entra checked: signature via the SWA trust domain JWKS, iss + sub + aud == federated credential $FIC."
echo; echo "Next: ./30-read-keyvault.sh $ENV"
