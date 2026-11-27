#!/bin/bash
# 10-azure-setup.sh <prod|dev> - Create the Azure side of the federation for one SWA environment (idempotent):
#   resource group -> Key Vault (RBAC) + demo secret -> user-assigned managed identity
#   -> federated identity credential (issuer = SWA trust domain, subject = workload SPIFFE ID, aud = api://AzureADTokenExchange)
#   -> role "Key Vault Secrets User" on this environment's secret only.
# Issuer and subject are read from a real JWT-SVID, so they always match what the agent issues.
source "$(dirname "$0")/lib.sh"
[ $# = 1 ] || die "usage: $0 <prod|dev>"
az_env "$1"
[ -n "$AZ_SUBSCRIPTION" ] && az account set -s "$AZ_SUBSCRIPTION"
TENANT=$(az account show --query tenantId -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)

echo "${B}[1] Issuer and subject from a live JWT-SVID ($WL, aud=$AZ_AUDIENCE)${N}"
JWT=$(fetch_jwt "$AZ_AUDIENCE"); [ -n "$JWT" ] || die "no JWT-SVID from $WL -> ./00-check-prereq.sh"
ISS=$(jwt_payload "$JWT" | jq -r .iss); SUB=$(jwt_payload "$JWT" | jq -r .sub)
echo "  issuer  $ISS"; echo "  subject $SUB"

echo "${B}[2] Resource group $AZ_RG ($AZ_LOCATION)${N}"
az group create -n "$AZ_RG" -l "$AZ_LOCATION" -o none && ok "$AZ_RG"

echo "${B}[3] Key Vault $KV_NAME (RBAC mode) + secret $KV_SECRET${N}"
if ! az keyvault show -n "$KV_NAME" -g "$AZ_RG" -o none 2>/dev/null; then
  az keyvault create -n "$KV_NAME" -g "$AZ_RG" -l "$AZ_LOCATION" --enable-rbac-authorization true -o none
fi
KV_ID=$(az keyvault show -n "$KV_NAME" -g "$AZ_RG" --query id -o tsv); ok "$KV_ID"
if [ -n "$ME" ]; then   # you need data-plane rights to write the demo secret
  az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
    --role "Key Vault Secrets Officer" --scope "$KV_ID" -o none 2>/dev/null || true
fi
for i in $(seq 1 12); do   # RBAC can take a minute to apply
  if az keyvault secret set --vault-name "$KV_NAME" -n "$KV_SECRET" --value "hello-from-azure-$ENV-$(date +%s)" -o none 2>/dev/null; then
    ok "secret $KV_SECRET"; break; fi
  [ $i = 12 ] && die "cannot write secret (need 'Key Vault Secrets Officer' on $KV_NAME)"; echo "  waiting for RBAC ($i/12)..."; sleep 10
done

echo "${B}[4] Managed identity $MI${N}"
az identity show -n "$MI" -g "$AZ_RG" -o none 2>/dev/null || az identity create -n "$MI" -g "$AZ_RG" -l "$AZ_LOCATION" -o none
CLIENT_ID=$(az identity show -n "$MI" -g "$AZ_RG" --query clientId -o tsv)
PRINCIPAL=$(az identity show -n "$MI" -g "$AZ_RG" --query principalId -o tsv)
echo "$CLIENT_ID" > "$AST/client_id"; echo "$TENANT" > "$AST/tenant_id"
ok "client id $CLIENT_ID   tenant id $TENANT"

echo "${B}[5] Federated identity credential $FIC${N}"
CUR=$(az identity federated-credential show -n "$FIC" --identity-name "$MI" -g "$AZ_RG" -o json 2>/dev/null || true)
if [ -n "$CUR" ] && [ "$(jq -r .issuer <<<"$CUR")" = "$ISS" ] && [ "$(jq -r .subject <<<"$CUR")" = "$SUB" ]; then
  ok "already set (issuer/subject unchanged)"
else
  [ -n "$CUR" ] && az identity federated-credential delete -n "$FIC" --identity-name "$MI" -g "$AZ_RG" --yes
  az identity federated-credential create -n "$FIC" --identity-name "$MI" -g "$AZ_RG" \
    --issuer "$ISS" --subject "$SUB" --audiences "$AZ_AUDIENCE" -o none
  ok "issuer=$ISS subject=$SUB aud=$AZ_AUDIENCE"
fi

echo "${B}[6] Role '$AZ_ROLE' on secret $KV_SECRET only${N}"
az role assignment create --assignee-object-id "$PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "$AZ_ROLE" --scope "$KV_ID/secrets/$KV_SECRET" -o none && ok "$MI -> $KV_SECRET"

echo; echo "${G}Done.${N} Azure can take 1-5 minutes to apply new credentials/roles. Next: ./20-get-azure-token.sh $ENV"
