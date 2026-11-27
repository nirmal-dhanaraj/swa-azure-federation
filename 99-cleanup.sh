#!/bin/bash
# 99-cleanup.sh [env|all] - Remove the Azure objects of this lab. Does not touch the SWA lab or the CyberArk tenant.
#   ./99-cleanup.sh prod   federated credential + identity of prod (and its role assignment)
#   ./99-cleanup.sh all    delete the whole resource group $AZ_RG (Key Vault is soft-deleted, then purged) + state/
source "$(dirname "$0")/lib.sh"
T=${1:-all}
[ -n "$AZ_SUBSCRIPTION" ] && az account set -s "$AZ_SUBSCRIPTION"
if [ "$T" = all ]; then
  read -rp "Delete resource group $AZ_RG and purge Key Vault $KV_NAME? [y/N] " a; [ "$a" = y ] || exit 0
  az group delete -n "$AZ_RG" --yes && ok "resource group $AZ_RG deleted"
  az keyvault purge -n "$KV_NAME" -l "$AZ_LOCATION" 2>/dev/null && ok "Key Vault $KV_NAME purged" || true
  rm -rf state; ok "state/ removed"
else
  az_env "$T"
  P=$(az identity show -n "$MI" -g "$AZ_RG" --query principalId -o tsv 2>/dev/null || true)
  [ -n "$P" ] && az role assignment delete --assignee "$P" --scope "$(az keyvault show -n "$KV_NAME" -g "$AZ_RG" --query id -o tsv)/secrets/$KV_SECRET" 2>/dev/null && ok "role assignment" || true
  az identity federated-credential delete -n "$FIC" --identity-name "$MI" -g "$AZ_RG" --yes 2>/dev/null && ok "$FIC" || true
  az identity delete -n "$MI" -g "$AZ_RG" 2>/dev/null && ok "$MI" || true
  rm -rf "$AST"
fi
