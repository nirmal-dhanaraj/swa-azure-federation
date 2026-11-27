# SWA → Azure: workloads get Azure tokens with their SPIFFE identity (no client secret)

Lab for the CyberArk use case **"Authenticate workloads with SPIFFE → Azure"**
([CyberArk docs](https://docs.cyberark.com/secrets-manager-saas/latest/en/content/conjurcloud/ccl-swa-azure.htm)):
a workload asks its local **SWA agent** for a JWT-SVID with audience `api://AzureADTokenExchange`, sends it to
**Microsoft Entra ID** as a client assertion, and gets an Azure access token for a **user-assigned managed identity**
through a **federated identity credential**. No Azure secret or certificate is stored anywhere.

The repo is self-contained, in two parts, both run on the **same Azure VM**:

| Folder | What | Deploy |
|---|---|---|
| [`swa-lab/`](swa-lab/README.md) | The SWA lab: SWA Servers (k3s), agents and workload containers `wl-prod`, `wl-dev`. Azure-VM adaptation of [huydd79/test-swa-docker](https://github.com/huydd79/test-swa-docker) (same as `swa-azure-lab`) | first, until `./55-full-test.sh` = 9/9 PASS |
| repo root | The Azure side: managed identities, federated credentials, Key Vault, token exchange | second (this README) |

Every file of test-swa-docker that the workflow uses is in `swa-lab/` (scripts, `image/`, `swa-go-test/`), in the
Azure-adapted version, plus `swa-lab/azure/` (VM bootstrap, copy-to-VM, autostart). Not copied: test-swa-docker's
`docs/` (explainer web pages, see https://huydd79.github.io/test-swa-docker/). The original has no license: credit to its author; ask them before reusing the code elsewhere.

## 1. How it works

```text
 wl-<env> container (SWA lab)          SWA Server / tenant              Microsoft Entra ID              Azure Key Vault
 ----------------------------          -------------------              ------------------              ---------------
 1 swa-agent api fetch jwt
     -a api://AzureADTokenExchange --> attest process (user, sha256)
                                   <-- JWT-SVID  iss = trust domain URL
                                                 sub = spiffe://<env>.../workload/swa-demo-sa
                                                 aud = api://AzureADTokenExchange
 2 POST /<tenant>/oauth2/v2.0/token
     client_id = <managed identity client id>
     client_assertion = JWT-SVID   ------------------------------------> federated credential fic-swa-<env>:
                                                                          iss, sub, aud must match exactly
                                       <-- GET <iss>/.well-known/openid-configuration + JWKS (public)
                                                                          verify signature
                                   <------------------------------------ Azure access token (~1 h)
 3 GET https://<kv>.vault.azure.net/secrets/swa-<env>-demo  ------------------------------------------> RBAC: Key Vault
                                                                                                       Secrets User on
                                                                                                       this secret only
```

| | prod | dev |
|---|---|---|
| Workload container (from SWA lab) | `wl-prod` | `wl-dev` |
| Subject (SPIFFE ID) | `spiffe://prod.swa.<domain>/ng-prod/workload/swa-demo-sa` | `spiffe://dev.swa.<domain>/ng-dev/workload/swa-demo-sa` |
| Issuer | `https://<subdomain>.secretsmgr.cyberark.cloud/api/swa/trust-domains/prod.swa.<domain>` | same with `dev` |
| Managed identity | `id-swa-prod` | `id-swa-dev` |
| Federated credential | `fic-swa-prod` | `fic-swa-dev` |
| Key Vault secret allowed | `swa-prod-demo` | `swa-dev-demo` |

The scripts read the real issuer and subject from a live JWT-SVID, so you never type them (if `LAB_ID` is set in the
SWA lab, the names include it).

## 2. Prerequisites

- The **SWA lab in `swa-lab/` is deployed and running** on the Azure VM (follow [swa-lab/README.md](swa-lab/README.md)
  section 3–4; `./55-full-test.sh` = 9/9 PASS). It needs the SWA bundle, the `conjur` CLI and your CyberArk tenant.
  Node group policy element 2 (`unix.path == "/opt/swa/bin/swa-agent"`) must still be there: this lab fetches the
  Azure JWT with the `swa-agent` CLI.
- An Azure subscription where you can create a resource group, managed identities, a Key Vault and **role
  assignments** (Owner, or Contributor + User Access Administrator).
- **Azure CLI** on the VM (step 3.1).
- Outbound HTTPS from the VM to `login.microsoftonline.com` and `*.vault.azure.net`.
- The SWA issuer's discovery document and JWKS must be **reachable from the Internet** (Entra fetches them).
  `00-check-prereq.sh` checks this.

## 3. Deploy (all on the Azure VM)

### 3.0 Deploy the SWA lab (part 1)

```bash
cd ~ && git clone https://github.com/nirmal-dhanaraj/swa-azure-federation.git
```

Then follow [swa-lab/README.md](swa-lab/README.md) sections 4.2–4.4 inside `~/swa-azure-federation/swa-lab`
(bootstrap, `config.env`, `conjur login`, `./01-get-token.sh`, deploy block) until 9/9 PASS.

### 3.1 Get the Azure CLI (once)

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

```bash
az login --use-device-code
```

### 3.2 Configure and check

```bash
cd ~/swa-azure-federation
cp config.env.example config.env && chmod 600 config.env
nano config.env          # set KV_NAME (globally unique), check AZ_LOCATION, LAB_DIR
```

```bash
./00-check-prereq.sh     # rerun until "All required items OK"
```

### 3.3 Create the Azure side

```bash
./10-azure-setup.sh prod && ./10-azure-setup.sh dev
```

Wait 1–5 minutes: Azure needs time to apply new federated credentials and role assignments.

### 3.3b Or: create the Azure side in the Azure Portal (no Azure CLI needed)

`./11-portal-values.sh` prints the exact names, issuer and subject to type in. Per environment:

1. **Key Vault** (once): Create → resource group `rg-swa-federation`, name = `KV_NAME`, permission model
   **Azure role-based access control**. Then Key Vault → Access control (IAM) → Add role assignment →
   **Key Vault Secrets Officer** → yourself (so you can add secrets). Secrets → Generate/Import `swa-prod-demo`, `swa-dev-demo`.
2. **Managed Identities** → Create `id-swa-<env>[-LAB_ID]` in the same resource group. Copy its **Client ID**.
3. Identity → Settings → **Federated credentials** → Add credential → scenario **Other** → Issuer URL, Subject
   identifier, Name, Audience `api://AzureADTokenExchange` as printed by `11`.
4. Key Vault → Secrets → `swa-<env>-demo` → **Access control (IAM)** → Add role assignment → **Key Vault Secrets User**
   → Managed identity → `id-swa-<env>...`.
5. In `config.env`: `AZ_TENANT_ID` (Microsoft Entra ID → Overview), `PROD_CLIENT_ID`, `DEV_CLIENT_ID`, `KV_NAME`.

**Only Contributor (cannot assign roles)?** Steps 1 and 4 are role assignments, which need Owner / User Access
Administrator. Self-service alternative: create **one Key Vault per environment** with permission model
**Vault access policy**, add access policies (yourself: secret management; `id-swa-<env>...`: secret **Get** only, on
its own vault), and set `PROD_KV_NAME` / `DEV_KV_NAME` in `config.env`. Each identity can then read only its own vault.

### 3.4 Try it

```bash
./20-get-azure-token.sh prod      # step by step: JWT-SVID -> Entra token
./30-read-keyvault.sh prod        # read swa-prod-demo with that token
./40-full-test.sh                 # allow/deny matrix, expect 12/12 PASS
```

Expected matrix (per environment, shown for prod):

| Case | Expected | Why |
|---|---|---|
| prod JWT → `id-swa-prod` | OK | iss/sub/aud match `fic-swa-prod` |
| prod token → secret `swa-prod-demo` | OK | role on that secret |
| prod token → secret `swa-dev-demo` | DENY (403) | no role on the other environment's secret |
| prod JWT → `id-swa-dev` | DENY (AADSTS70021/700213) | subject/issuer do not match `fic-swa-dev` |
| prod JWT with `aud=conjur` → `id-swa-prod` | DENY | wrong audience |
| `wl-prod` as `root` asks for a JWT | DENY | SWA node group policy (user) |

## 4. Files

| Script | Purpose |
|---|---|
| `config.env.example` → `config.env` | Azure settings and the path of the SWA lab. `config.env` is git-ignored |
| `lib.sh` | Loads the SWA lab's settings (`env_load`), `fetch_jwt`, `exchange` (JWT-SVID → Entra token) |
| `00-check-prereq.sh` | Tools, `az login`, workload containers, live JWT-SVID, issuer discovery + JWKS reachable. Reports only |
| `10-azure-setup.sh <env>` | Resource group, Key Vault (RBAC) + demo secret, managed identity, federated credential, role on the secret |
| `11-portal-values.sh [env]` | Portal route: print the values to type into the Azure Portal (issuer, subject, names) |
| `20-get-azure-token.sh <env>` | Explained exchange; caches the Azure token in `state/<env>/azure_token` (mode 600) |
| `30-read-keyvault.sh <env> [secret]` | Read a Key Vault secret with the cached token (`SHOW=1` prints the value) |
| `40-full-test.sh` | 12-case allow/deny matrix |
| `99-cleanup.sh [env\|all]` | Remove one environment's identity, or both + the Key Vault (purged). Never deletes the resource group |
| `swa-lab/` | The SWA lab (from test-swa-docker, Azure-adapted); its own scripts and README |

## 5. Manual commands (what the scripts do)

```bash
# Azure side (one environment)
az identity create -n id-swa-prod -g rg-swa-federation
az identity federated-credential create -n fic-swa-prod --identity-name id-swa-prod -g rg-swa-federation \
  --issuer "<iss of the JWT-SVID>" --subject "<SPIFFE ID>" --audiences api://AzureADTokenExchange
az role assignment create --assignee-object-id <principalId> --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope <keyvault-id>/secrets/swa-prod-demo

# Workload side
JWT=$(docker exec --user swa-demo-sa wl-prod /opt/swa/bin/swa-agent api fetch jwt \
  -a api://AzureADTokenExchange -s /run/swa-agent/api.sock --output json | jq -r '..|strings|select(startswith("eyJ"))' | head -1)
curl -s -X POST https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token \
  -d client_id=<client-id> -d grant_type=client_credentials -d scope=https://vault.azure.net/.default \
  -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
  --data-urlencode client_assertion="$JWT" | jq -r .access_token
```

## 6. Troubleshooting

| Symptom | Fix |
|---|---|
| `no JWT-SVID with aud=api://AzureADTokenExchange` | `DEBUG=1 ./00-check-prereq.sh`; SWA lab running? policy element 2 still in the node group? |
| `no OpenID discovery document` | Entra cannot validate the issuer: check the issuer URL in the JWT and the CyberArk docs / support |
| `AADSTS70021` / `AADSTS700213` | iss/sub/aud do not match the federated credential: rerun `./10-azure-setup.sh <env>`, wait a few minutes |
| `AADSTS700211` | issuer not found on any federated credential (typo, trailing `/`) |
| `AADSTS50027` / signature errors | Entra could not verify the JWT signature (JWKS not reachable, key rotated, algorithm not accepted) |
| Key Vault `403` on its own secret | role assignment not applied yet: wait 1–5 minutes and retry |
| `KV_NAME` already taken | Key Vault names are global: pick another one in `config.env` |

## 7. Notes

- **Production**: give the real workload binary its own pinned-hash policy and fetch the JWT through the SPIFFE
  Workload API (e.g. go-spiffe / Azure SDK `ClientAssertionCredential`). The `swa-agent` CLI route is for the demo.
- One managed identity can have **at most 20 federated credentials**; issuer and subject are matched **exactly**
  (case-sensitive).
- JWT-SVIDs live ~5 minutes; the Azure token ~1 hour. Request a new JWT-SVID for each exchange.
- Clean up with `./99-cleanup.sh all` when done (identities + Key Vault only; the resource group is kept). Portal route: delete the two identities and the Key Vault by hand.
