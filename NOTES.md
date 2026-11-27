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
- **18:39 – token exchange works for prod**: `./20-get-azure-token.sh prod` → HTTP 200, Entra token for
  `id-swa-prod-mylab` (~24 h). **RS512 JWT-SVIDs are accepted by Entra** (risk closed). Using access-policy vaults
  `kv-swa-nirmal-prod` / `kv-swa-nirmal-dev`.
- **18:50 – DONE: `./40-full-test.sh` = 12/12 PASS** (prod + dev: token OK, own secret OK, other env's vault 403,
  other identity AADSTS700211, aud=conjur AADSTS700212, root denied by SWA node group policy).
- Lessons: the issuer host is the CyberArk tenant (`tiger-prod.secretsmgr...`) for **both** environments, only
  `trust-domains/<td>` differs (a `tiger-dev` typo gave AADSTS700211); secret names must match exactly
  (`swa-dev-demo` missing gave 404). Tenant ID without Entra access: Key Vault Overview → Directory ID.

## Next steps

- [x] SWA lab running (existing test-swa-docker on the VM)
- [x] Clone this repo on the VM, `config.env`, `./00-check-prereq.sh` all OK
- [x] Azure objects via the Portal (identities, federated credentials, two access-policy vaults)
- [x] `./20`, `./30`, `./40-full-test.sh` → **12/12 PASS**
- [ ] Optional: ask an admin for role assignments to use the RBAC single-vault design from the CyberArk docs
- [ ] Optional: production-style client (Azure SDK / go-spiffe with its own pinned-hash policy) instead of the swa-agent CLI
- [ ] When done: delete the two identities and the vaults in the Portal (keep `rg-nirmal-lab`)

## Open risks

- `swa-lab/` is a copy: fixes made in swa-azure-lab must be copied here too (or stop using swa-azure-lab).
- test-swa-docker has no license; this repo was made public by choice (2026-11-27). If the author objects, remove `swa-lab/` or make the repo private.

- **Issuer discovery**: assumed the issuer is the trust domain URL (`<tenant>/api/swa/trust-domains/<td>`, as the
  SWA lab's authn-jwt uses) and that it serves `/.well-known/openid-configuration` publicly. `00` checks; the scripts
  always use the `iss` from a real JWT, so only reachability matters.
- ~~**Signing algorithm**~~ (resolved 2026-11-27: Entra accepted RS512): the SWA lab saw RS512 JWT-SVIDs. If Entra rejects that algorithm, the exchange fails with a
  signature error → check the CyberArk docs for a setting on the trust domain / JWT key type.
- Role assignments and federated credentials take 1–5 minutes to apply; retry before debugging.
