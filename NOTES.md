# Project notes & progress log

Last updated: 2026-11-27.

## What this project is

Azure add-on to [swa-azure-lab](https://github.com/nirmal-dhanaraj/swa-azure-lab): SWA workloads swap their SPIFFE
JWT-SVID for a Microsoft Entra token (managed identity + federated credential), then read Azure Key Vault. Based on
the CyberArk page "Authenticate workloads with SPIFFE → Azure" (ccl-swa-azure.htm). Details: [README.md](README.md).

## What was done (session 1, 2026-11-27)

1. Created this separate repo for the Azure use case; it reuses the running SWA lab on the same VM (`LAB_DIR`).
2. Scripts `00` (checks), `10` (Azure setup per env), `20` (token exchange), `30` (Key Vault read), `40` (12-case
   matrix), `99` (cleanup). Syntax-checked only: **not yet run against a real Azure tenant / SWA tenant**.

## Next steps

- [ ] Finish the SWA lab first (see its NOTES.md) → 9/9 PASS
- [ ] On the VM: clone this repo, install Azure CLI, `az login --use-device-code`
- [ ] `cp config.env.example config.env`, set `KV_NAME`, run `./00-check-prereq.sh` until all OK
- [ ] `./10-azure-setup.sh prod && ./10-azure-setup.sh dev`, wait a few minutes
- [ ] `./20-get-azure-token.sh prod`, `./30-read-keyvault.sh prod`, `./40-full-test.sh` → expect 12/12 PASS

## Open risks

- **Issuer discovery**: assumed the issuer is the trust domain URL (`<tenant>/api/swa/trust-domains/<td>`, as the
  SWA lab's authn-jwt uses) and that it serves `/.well-known/openid-configuration` publicly. `00` checks; the scripts
  always use the `iss` from a real JWT, so only reachability matters.
- **Signing algorithm**: the SWA lab saw RS512 JWT-SVIDs. If Entra rejects that algorithm, the exchange fails with a
  signature error → check the CyberArk docs for a setting on the trust domain / JWT key type.
- Role assignments and federated credentials take 1–5 minutes to apply; retry before debugging.
