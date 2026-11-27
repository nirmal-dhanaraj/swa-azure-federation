#!/bin/bash
# 11-portal-values.sh [prod|dev] - Print the exact values to type into the Azure Portal (Portal route, instead of 10).
# Issuer and subject come from a live JWT-SVID of the workload container, so they match exactly.
source "$(dirname "$0")/lib.sh"
for e in ${1:-$ENVS}; do
  az_env "$e"
  JWT=$(fetch_jwt "$AZ_AUDIENCE"); [ -n "$JWT" ] || die "no JWT-SVID from $WL -> ./00-check-prereq.sh"
  ISS=$(jwt_payload "$JWT" | jq -r .iss); SUB=$(jwt_payload "$JWT" | jq -r .sub)
  cat <<EOF

${B}================ $ENV ================${N}
${B}Key Vault secret${N}            vault: $KV   name: $KV_SECRET   (any value, e.g. hello-from-azure-$ENV)
${B}Managed identity${N}            name: $MI   resource group: $AZ_RG   region: $AZ_LOCATION
${B}Federated credential${N}        (identity -> Settings -> Federated credentials -> Add credential)
  Federated credential scenario: Other
  Issuer URL                   : $ISS
  Subject identifier           : $SUB
  Name                         : $FIC
  Audience                     : $AZ_AUDIENCE
${B}Role assignment${N}             Key Vault -> Objects -> Secrets -> $KV_SECRET -> Access control (IAM) -> Add role assignment
  Role: $AZ_ROLE   Assign access to: Managed identity -> $MI
${B}Then in config.env${N}          ${ENV^^}_CLIENT_ID="<Client ID from $MI -> Overview>"
EOF
done
echo
echo "Also in config.env: AZ_TENANT_ID=\"<Microsoft Entra ID -> Overview -> Tenant ID>\" and KV_NAME=\"<your Key Vault name>\""
