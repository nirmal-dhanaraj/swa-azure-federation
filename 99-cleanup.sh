#!/bin/bash
# 99-cleanup.sh [env|all] - Remove ONLY the Azure objects of this demo (never the resource group: it may hold your VM).
#   ./99-cleanup.sh prod   role assignment, federated credential and managed identity of prod
#   ./99-cleanup.sh all    both environments + the Key Vault $KV_NAME (deleted, then purged) + local state/
# Needs the Azure CLI (az login). Portal alternative: delete the identities and the Key Vault by hand.
# Does not touch the SWA lab or the CyberArk tenant.
source "$(dirname "$0")/lib.sh"
T=${1:-all}
command -v az >/dev/null || die "Azure CLI not installed: delete the objects in the Portal, or install az"
[ -n "$AZ_SUBSCRIPTION" ] && az account set -s "$AZ_SUBSCRIPTION"
KV_ID=$(az keyvault show -n "$KV_NAME" -g "$AZ_RG" --query id -o tsv 2>/dev/null || true)

del_env(){
  az_env "$1"; echo "${B}[$ENV]${N}"
  local P; P=$(az identity show -n "$MI" -g "$AZ_RG" --query principalId -o tsv 2>/dev/null || true)
  [ -n "$P" ] && [ -n "$KV_ID" ] && az role assignment delete --assignee "$P" --scope "$KV_ID/secrets/$KV_SECRET" 2>/dev/null && ok "role assignment" || true
  az identity federated-credential delete -n "$FIC" --identity-name "$MI" -g "$AZ_RG" --yes 2>/dev/null && ok "$FIC" || true
  az identity delete -n "$MI" -g "$AZ_RG" 2>/dev/null && ok "$MI" || true
  rm -rf "$AST"
}

if [ "$T" = all ]; then
  read -rp "Delete identities ($ENVS) and Key Vault $KV_NAME in $AZ_RG? The resource group itself is kept. [y/N] " a
  [ "$a" = y ] || exit 0
  for e in $ENVS; do del_env "$e"; done
  if [ -n "$KV_ID" ]; then
    az keyvault delete -n "$KV_NAME" -g "$AZ_RG" && ok "Key Vault $KV_NAME deleted"
    az keyvault purge -n "$KV_NAME" 2>/dev/null && ok "Key Vault $KV_NAME purged" || warn "purge failed (purge protection?) - it is removed after the retention days"
  fi
  rm -rf state; ok "state/ removed"
else
  del_env "$T"
fi
