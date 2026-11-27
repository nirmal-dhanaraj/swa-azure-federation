# Project notes & progress log

Last updated: 2026-11-27.

## What this project is

Self-contained lab: `swa-lab/` (SWA lab from huydd79/test-swa-docker, Azure-adapted, same as swa-azure-lab) + Azure add-on at the root. SWA workloads swap their SPIFFE
JWT-SVID for a Microsoft Entra token (managed identity + federated credential), then read Azure Key Vault. Based on
the CyberArk page "Authenticate workloads with SPIFFE → Azure" (ccl-swa-azure.htm). Details: [README.md](README.md).

## What was done (session 1, 2026-11-27)

1. Created this separate repo for the Azure use case; it reuses the running SWA lab on the same VM (`LAB_DIR`).
2. Scripts `00` (checks), `10` (Azure setup per env), `20` (token exchange), `30` (Key Vault read), `40` (12-case
   matrix), `99` (cleanup). Syntax-checked only: **not yet run against a real Azure tenant / SWA tenant**.

3. Same day: copied every test-swa-docker file the workflow needs into `swa-lab/` (Azure-adapted versions from
   swa-azure-lab; not `docs/`). `LAB_DIR` now defaults to `./swa-lab`; `push-to-vm.sh` targets `~/swa-azure-federation/swa-lab`.

## Session 2 (2026-11-27)

- Using the **already running test-swa-docker lab** on the VM (`LAB_DIR=/home/ndhanaraj/test-swa-docker`, run as root,
  LAB_ID `mylab`, trust domains `prod|dev.mylab.swa.example.com`): status OK for prod and dev.
- Azure objects are created in the **Portal** (no az CLI needed): new `11-portal-values.sh` prints issuer/subject/names;
  client ids / tenant id go into `config.env` (`AZ_TENANT_ID`, `PROD_CLIENT_ID`, `DEV_CLIENT_ID`).
- Key Vault `kv-swa-nirmal01` created in **existing** RG `rg-nirmal-lab` (Australia East, RBAC, soft-delete 7 days,
  no purge protection), network: selected networks = VM VNet/subnet (service endpoint) + user's client IP.
- `99-cleanup.sh` changed: never deletes the resource group (it may hold the VM), only identities + Key Vault.
- User has **Contributor** only on the subscription: cannot do role assignments ("operation is not allowed by RBAC").
  Options: admin does the role assignments, or one vault per environment with **Vault access policy** model
  (scripts now support `PROD_KV_NAME` / `DEV_KV_NAME`).

## Next steps

- [ ] Deploy the SWA lab in `swa-lab/` first (swa-lab/README.md, open items in swa-azure-lab's NOTES.md) → 9/9 PASS
- [ ] On the VM: clone this repo, install Azure CLI, `az login --use-device-code`
- [ ] `cp config.env.example config.env`, set `KV_NAME`, run `./00-check-prereq.sh` until all OK
- [ ] `./10-azure-setup.sh prod && ./10-azure-setup.sh dev`, wait a few minutes
- [ ] `./20-get-azure-token.sh prod`, `./30-read-keyvault.sh prod`, `./40-full-test.sh` → expect 12/12 PASS

## Open risks

- `swa-lab/` is a copy: fixes made in swa-azure-lab must be copied here too (or stop using swa-azure-lab).
- test-swa-docker has no license; this repo was made public by choice (2026-11-27). If the author objects, remove `swa-lab/` or make the repo private.

- **Issuer discovery**: assumed the issuer is the trust domain URL (`<tenant>/api/swa/trust-domains/<td>`, as the
  SWA lab's authn-jwt uses) and that it serves `/.well-known/openid-configuration` publicly. `00` checks; the scripts
  always use the `iss` from a real JWT, so only reachability matters.
- **Signing algorithm**: the SWA lab saw RS512 JWT-SVIDs. If Entra rejects that algorithm, the exchange fails with a
  signature error → check the CyberArk docs for a setting on the trust domain / JWT key type.
- Role assignments and federated credentials take 1–5 minutes to apply; retry before debugging.
