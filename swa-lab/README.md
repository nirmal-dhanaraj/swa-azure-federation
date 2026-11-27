# CyberArk Secure Workload Access (SWA) Lab on an Azure VM (prod / dev)

Hands-on lab that runs the **SWA Server** (vendor helm chart) on a single-node **k3s cluster inside a Docker
container**, and the **SWA Agent** + workload in plain Docker containers (one per environment, simulating a machine),
all on **one Azure Linux VM**, against a CyberArk / Idira Secrets Manager SaaS tenant. Two isolated environments
(`prod`, `dev`) show how a workload gets a SPIFFE **JWT-SVID** without holding any secret, exchanges it for a Secrets
Manager access token, and reads only the secrets of its own environment.

Based on [huydd79/test-swa-docker](https://github.com/huydd79/test-swa-docker) (concept explainer:
https://huydd79.github.io/test-swa-docker/). This fork adapts it to an existing Azure Ubuntu VM:

| Change | Why |
|---|---|
| `azure/vm-bootstrap.sh` | One command installs Docker Engine, kubectl, helm and tools on Ubuntu 22.04/24.04 (x64 or Arm64) |
| `azure/push-to-vm.sh` | Copy the lab + SWA bundle + conjur CLI from your workstation over SSH (never copies `config.env`, `.token`, `state/`) |
| `API_BIND="auto"` (default) | The SWA Server ports 18443/18543 bind to the docker bridge gateway (e.g. `172.17.0.1`) – the agents reach them, the VNet/Internet cannot. Nothing to open in the NSG |
| `00-check-prereq.sh` Azure section | Detects the VM via IMDS, checks cgroup v2, RAM, disk, port exposure; apt install hints |
| `azure/install-autostart.sh` | Optional systemd unit so the lab comes back after Azure auto-shutdown / deallocate |
| `CA_ORG`, `LAB_ID="azlab"` | No author-specific names in certificates; separate names if you share a tenant with another lab |

| | |
|---|---|
| SWA version | 1.2.3 (release bundle `swa-release-v1.2.3.tgz`); originally tested with 1.1.4 – bundle file names are auto-detected, set `SWA_VERSION` to your bundle |
| VM | Ubuntu Server 22.04 / 24.04 LTS, ≥ 2 vCPU / 4 GiB RAM / 30 GiB disk (e.g. `Standard_B2s`, `Standard_B2als_v2`, Arm64 `Standard_B2pls_v2`) |
| Runtime | Docker Engine + `kubectl` + `helm` (installed by `azure/vm-bootstrap.sh`); k3s `v1.35` in container `swa-k3s` |
| Purpose | Demo / learning lab – not hardened for production |

---

## 1. Components

Each environment is its own trust boundary: trust domain, server group, x509pop CA, SWA Server, node group and
authenticator. Both SWA Servers run in one k3s cluster (namespaces `swa-prod`, `swa-dev`); a workload container
outside k3s simulates one machine (agent + service account + client).

```text
                       CyberArk SaaS tenant
 +-------------------------------------------------------------------------------+
 |  Secrets Manager (SWA control plane + secrets)                                |
 |                                                                               |
 |   trust domain prod.swa.<domain>            trust domain dev.swa.<domain>     |
 |    +- server group sg-k3s-prod               +- server group sg-k3s-dev       |
 |    |   +- x509pop CA (state/prod/pki)        |   +- x509pop CA (state/dev/pki)|
 |    |   +- component swa-server-prod          |   +- component swa-server-dev  |
 |    |   +- node group ng-prod (policy)        |   +- node group ng-dev (policy)|
 |    +- authn-jwt/swa-prod                     +- authn-jwt/swa-dev             |
 |                                                                               |
 |   SAFE_POLICY (e.g. data/vault/<safe>)  <-- !permit per variable per host     |
 |                                                                               |
 |  Identity (admin login + MFA -> .token, used by the setup scripts)            |
 +----------------------------^-----------------------------^--------------------+
                              | HTTPS 443                   | HTTPS 443
 +----------------------------|-----------------------------|--------------------+
 |  Azure VM                  |                             |                    |
 |   +------------------------|-----------------------------|----------------+   |
 |   | container swa-k3s (k3s v1.35, privileged, volume swa-k3s)             |   |
 |   |  +---------------------+-----+       +---------------+------------+   |   |
 |   |  | ns swa-prod               |       | ns swa-dev                 |   |   |
 |   |  |  deploy swa-server (helm) |       |  deploy swa-server (helm)  |   |   |
 |   |  |  SA token aud=conjur      |       |  SA token aud=conjur       |   |   |
 |   |  |  svc NodePort 30843       |       |  svc NodePort 30943        |   |   |
 |   |  +-------------^-------------+       +-------------^--------------+   |   |
 |   +----------------|------------------------------------|-----------------+   |
 |        published host :18443 (Mac: 127.0.0.1:28443)     host :18543 (28543)   |
 |                    | mTLS via host gateway              | mTLS via host gateway|
 |   +----------------+----------+         +---------------+------------+        |
 |   | wl-prod  (= one machine)  |         | wl-dev  (= one machine)    |        |
 |   |  swa-agent (root)         |         |  swa-agent (root)          |        |
 |   |   x509pop cert CN=ng-prod |         |   x509pop cert CN=ng-dev   |        |
 |   |   /run/swa-agent/api.sock |         |   /run/swa-agent/api.sock  |        |
 |   |  swa-demo-sa (nologin)    |         |  swa-demo-sa (nologin)     |        |
 |   |   swa-go-test, swa-test.sh|         |   swa-go-test, swa-test.sh |        |
 |   +---------------------------+         +----------------------------+        |
 +-------------------------------------------------------------------------------+
```

| | prod | dev |
|---|---|---|
| Trust domain | `prod.swa.<BASE_DOMAIN>` | `dev.swa.<BASE_DOMAIN>` |
| Server group / CA | `sg-k3s-prod` / `state/prod/pki` | `sg-k3s-dev` / `state/dev/pki` |
| SWA Server (k3s) | ns `swa-prod`, component `swa-server-prod`, NodePort 30843 → host `:18443` | ns `swa-dev`, component `swa-server-dev`, NodePort 30943 → host `:18543` |
| Server JWT (to the tenant) | k3s SA token: iss `https://kubernetes.default.svc.cluster.local`, sub `system:serviceaccount:swa-prod:swa-server` | same iss, sub `system:serviceaccount:swa-dev:swa-server` |
| Node group (= CN of agent cert) | `ng-prod` | `ng-dev` |
| Workload container | `wl-prod` | `wl-dev` |
| SPIFFE ID | `spiffe://prod.swa.<BASE_DOMAIN>/ng-prod/workload/swa-demo-sa` | `spiffe://dev.swa.<BASE_DOMAIN>/ng-dev/workload/swa-demo-sa` |
| Workload authenticator | `authn-jwt/swa-prod` | `authn-jwt/swa-dev` |
| Secrets allowed | `PROD_SECRETS` | `DEV_SECRETS` |

Node group registration policy (both environments; array elements are OR'ed):

```text
1. unix.user == "swa-demo-sa" && unix.sha256 == "<sha256 of swa-go-test>"
2. unix.user == "swa-demo-sa" && unix.path  == "/opt/swa/bin/swa-agent"   # only for the swa-test.sh demo; remove afterwards
```

Note: the tenant appends a short id to the server authenticator name (e.g. `swa-server-prod-01a111da`). It is the
first 8 hex characters of the component UUID (UUIDv7) generated at registration; the scripts read the full URL from
the API response into `state/<env>/authn_id`, so you never type it.

## 2. Communication flows

### 2.1 Server bootstrap (once per start, then every `syncInterval` = 15m in the chart)

```text
 k3s (kubelet)                 swa-server (ns swa-<env>)              Tenant
 -------------                 -------------------------              ------
 projected SA token aud=conjur,
 1h, auto-rotated
   --> /var/run/secrets/tokens/swa-token
                               reads token (tokenPath)
                               POST authn-jwt/swa-server-<env>-xxxx --> verifies against the k3s JWKS
                                                                        registered inline by 10-tenant-setup.sh
                                                                   <-- access token
                               creates internal CA, uploads keys --> trust domain JWKS / CA bundle
                               pulls node groups + policies      <-- (sync every 15m)
```

### 2.2 Agent attestation (container start)

```text
 swa-agent (wl-<env>)                                  swa-server-<env>          Tenant
 --------------------                                  ----------------          ------
 GET .well-known/ca-bundles  ------------------------------------------------->  trust bundle
 connect host-gw:<API_PORT> -> k3s NodePort (TLS, server cert checked against bundle)
 x509pop: present cert CN=<node group> + prove key --> verify chain to the
                                                       server group CA, map CN
                                                       to node group
                                                   <-- agent SVID (mTLS from now on)
```

### 2.3 Workload gets a secret

```text
 swa-go-test (uid swa-demo-sa)      swa-agent              swa-server            Secrets Manager
 -----------------------------      ---------              ----------            ---------------
 1 FetchJWTSVID(aud=conjur) ------> socket peer -> PID
                                    /proc: user, uid, gid,
                                    path, sha256
                                    --- attributes -----> evaluate node group
                                                          CEL policy
                                    <-- JWT-SVID (RS512, 5 min) or
                                        "no matching registration policy"
   <-- JWT-SVID
 2 POST authn-jwt/swa-<env>/conjur/host%2F...%2F<SPIFFE ID>/authenticate (jwt=...) ------>
                                                       verify JWT with trust domain JWKS,
                                                       sub == host annotation, host in group apps
   <------------------------------------------------------------------------ access token
 3 GET secrets/conjur/variable/<SAFE_POLICY>/<account>/password ------------>
                                                       !permit read,execute on this host?
   <------------------------------------------------------------------------ value | 404
```

The workload holds no credential. Identity = which process (user + binary hash) talks to the local agent on an
attested node.

## 3. Prerequisites

### 3.1 From CyberArk / Idira (not downloadable publicly)

- An Idira (CyberArk Identity Security Platform) tenant with **Secrets Manager SaaS** and **Secure Workload Access**
  enabled: `https://<subdomain>.secretsmgr.cyberark.cloud` and its Identity tenant `https://<tenant-id>.id.cyberark.cloud`.
- An admin user (Identity login with MFA) who can manage SWA trust domains / server groups / node groups and load
  Secrets Manager policies (e.g. member of the Secrets Manager admin group).
- A safe synced to Secrets Manager (`data/vault/<safe>`) holding **test** accounts used as prod and dev secrets
  (`<account>/username`, `<account>/password`). The demo can print their values.
- The **SWA release bundle** `swa-release-v1.2.3.tgz` (contains `binaries/swa-agent_<ver>_linux_<arch>/swa-agent`,
  `container-images/swa-server-<ver>-<amd64|arm64v8>.tar`, `helm/swa-server-0.1.0.tgz`). The `swa-server` image is
  **not** on Docker Hub; it is imported into k3s from the tar.
- The **Secrets Manager CLI** `conjur` (v9.x, Linux build matching the VM arch).

### 3.2 The Azure VM (you already have it)

- **Ubuntu Server 22.04 or 24.04 LTS** (cgroup v2 – required by the k3s v1.35 kubelet), x64 or Arm64.
- Size ≥ 2 vCPU / 4 GiB RAM, ≥ 30 GiB OS disk (k3s ≈ 0.6 GiB RAM + two small workload containers; images ≈ 3 GiB).
- **Inbound (NSG)**: only SSH (22) – ideally restricted to your IP, or use Azure Bastion / `az ssh vm`.
  No other inbound port is needed: the tenant never connects to the VM, the agents reach the servers via the
  docker bridge, and kubectl/helm use `127.0.0.1:16443` on the VM.
- **Outbound**: HTTPS 443 to `*.secretsmgr.cyberark.cloud`, `*.id.cyberark.cloud`, Docker Hub
  (`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`), `proxy.golang.org`/`sum.golang.org`
  (client build), `download.docker.com`, `dl.k8s.io`, `get.helm.sh`, `archive.ubuntu.com`. Default Azure outbound
  allows all of this; if you route egress through **Azure Firewall / NVA / proxy**, allow these FQDNs.
- A Linux user with `sudo` (e.g. `azureuser`).

## 4. Deploy to the Azure VM

### 4.1 Copy the lab to the VM (on your workstation)

```bash
git clone https://github.com/nirmal-dhanaraj/swa-azure-federation.git && cd swa-azure-federation/swa-lab
./azure/push-to-vm.sh azureuser@<vm-public-ip> ~/Downloads/swa-release-v1.2.3.tgz ~/Downloads/conjur
#   other key:  SSH_OPTS="-i ~/.ssh/azure_vm" ./azure/push-to-vm.sh ...
```

Alternative: `git clone` directly on the VM, then `scp` the bundle and extract it with
`mkdir -p release && tar -xzf swa-release-v1.2.3.tgz -C release`.

### 4.2 Prepare the VM (once)

```bash
ssh azureuser@<vm-public-ip>
cd ~/swa-azure-federation/swa-lab
sudo ./azure/vm-bootstrap.sh                          # Docker, kubectl, helm, tools, docker group, UFW rule
sudo install -m 0755 conjur /usr/local/bin/conjur     # Secrets Manager CLI copied by push-to-vm.sh
exit                                                  # log out/in so the docker group applies
```

### 4.3 Configure and check (interactive, on the VM)

```bash
cd ~/swa-azure-federation/swa-lab
cp config.env.example config.env && chmod 600 config.env
vi config.env                         # fill every <placeholder> in the EDIT sections
./00-check-prereq.sh                  # fix every MISS, rerun until "All required items OK"

conjur init                           # first time: Secrets Manager SaaS, https://<subdomain>.secretsmgr.cyberark.cloud
conjur login                          # admin user + MFA (used by 10/40/99 for policy loads)
./01-get-token.sh                     # admin API token -> ./.token (short-lived: run right before 4.4)
```

### 4.4 Deploy and verify (copy and paste)

Non-interactive, a few minutes (the first run pulls `rancher/k3s`, `busybox`, `golang`, `alpine`). It stops at the first
failing step – fix it and paste again (every step is idempotent).

```bash
./05-k3s-up.sh \
&& ./10-tenant-setup.sh prod && ./10-tenant-setup.sh dev \
&& ./20-server-install.sh prod && ./20-server-install.sh dev \
&& ./30-build-image.sh && ./31-workload-run.sh prod && ./31-workload-run.sh dev \
&& ./40-grant.sh prod && ./40-grant.sh dev \
&& ./53-lab-status.sh && ./55-full-test.sh
```

| Step | What it does |
|---|---|
| `05-k3s-up.sh` | k3s cluster in Docker (server ports bound to the docker bridge gateway) + SWA Server image import |
| `10-tenant-setup.sh <env>` | Tenant objects: CA, trust domain, server group, server component (k3s JWKS), node group (pins the `swa-go-test` sha256, building it first if needed), `authn-jwt/swa-<env>` |
| `20-server-install.sh <env>` | SWA Server via helm in ns `swa-<env>` |
| `30-build-image.sh`, `31-workload-run.sh <env>` | Workload image, agent certificate and workload containers |
| `40-grant.sh <env>` | Workload host annotation, group `apps`, permissions on the environment's own secrets |
| `53-lab-status.sh`, `55-full-test.sh` | Verify: every environment gets a JWT-SVID and an access token; matrix shows 9/9 PASS |

If `01-get-token.sh`'s token expires during the block (~8 min), rerun `./01-get-token.sh` and paste the block again.

### 4.5 Optional: survive VM restarts

```bash
sudo ./azure/install-autostart.sh     # systemd unit swa-lab: runs 51-lab-start.sh after docker on boot
```

Useful with Azure **auto-shutdown** (VM → Operations → Auto-shutdown) to save cost: deallocate at night, start
the VM and the lab comes back by itself (`journalctl -u swa-lab`). Without it, run `./51-lab-start.sh` after a start.

## 5. Azure-specific notes

- **Ports / NSG**: with `API_BIND="auto"` the k3s container publishes `127.0.0.1:16443` (kube-apiserver) and
  `<bridge-gw>:18443/18543` (SWA Servers). `docker port swa-k3s` shows it; `00-check-prereq.sh` warns if anything is on
  `0.0.0.0`. If you set `API_BIND=""` (all interfaces), keep 18443/18543 **closed** in the NSG – Docker-published ports
  bypass UFW.
- **Port mappings are fixed when `05` creates the container.** To change `API_BIND` / ports:
  `docker rm -f swa-k3s && ./05-k3s-up.sh` (the `swa-k3s` volume and thus the registered JWKS are kept).
- **DNS**: Azure adds a search domain (`*.internal.cloudapp.net`); `05` already strips search domains for the pods
  so the tenant FQDN resolves correctly. Containers use Azure DNS (168.63.129.16) via systemd-resolved upstreams.
- **UFW**: Ubuntu images ship UFW inactive. If you enable it, `vm-bootstrap.sh` (rerun) adds
  `ufw allow in on docker0 to any port 18443,18543 proto tcp` so the agents can reach the servers.
- **Arm64 VMs** (Ampere, `*p*_v5/v6` sizes) work: the scripts pick `swa-agent_*_linux_arm64` and the `arm64v8` image.
- **Egress through Azure Firewall / proxy with TLS inspection** breaks the agent ↔ tenant / server mTLS and the
  Go module download – exempt the FQDNs in 3.2 from inspection.
- **Secrets on the VM**: `config.env`, `.token` and `state/` (x509pop CA keys, agent keys) live in the lab directory
  (mode 600/700). Use a dedicated VM, enable disk encryption (default SSE + optionally encryption at host), and run
  `./99-cleanup.sh all` when you are done.
- **Cost**: a B2s/B2als_v2 runs the whole lab; stop (deallocate) it when not in use.

## 6. Files

| Script | Purpose |
|---|---|
| `config.env.example` → `config.env` | Lab settings (tenant, domain, safe, secrets, bundle). `config.env` is git-ignored |
| `lib.sh` | Shared helpers: `env_load`, API calls, conjur policy loads, k3s helpers + image import, host gateway detection |
| `00-check-prereq.sh` | Checks config, tools, bundle, network, ports, conjur login, token. Reports only, never installs |
| `01-get-token.sh` | Admin login (Identity + MFA, push approval supported) → `./.token` (mode 600) |
| `05-k3s-up.sh` | Run k3s container `swa-k3s` (volume `swa-k3s`, port mappings), write `state/k3s.kubeconfig`, import the server image |
| `10-tenant-setup.sh <env>` | x509pop CA → trust domain → server group → server component (k3s JWKS inline; re-registers if the k3s key changed) → node group (policy) → `authn-jwt/swa-<env>` |
| `20-server-install.sh <env>` | `helm upgrade --install` the vendor chart in ns `swa-<env>`, pin NodePort, wait Ready |
| `30-build-image.sh` | Build `localhost/swa-lab-workload:1.0` (alpine + swa-agent + swa-go-test + swa-test.sh) |
| `31-workload-run.sh <env>` | Issue agent x509pop cert (CN = node group) and run `wl-<env>` |
| `40-grant.sh <env>` | First fetch (tenant creates the workload host) → annotation → group `apps` → `!permit` on the env secrets |
| `51-lab-start.sh [env]` | Start k3s, scale swa-server to 1 and wait Ready, start the workload |
| `52-lab-stop.sh [env]` | With env: stop `wl-<env>` + scale its server to 0. Without: stop workloads and the k3s container. Deletes nothing |
| `53-lab-status.sh [env]` | k3s node, server deployments, workload containers, JWT-SVID + access token check |
| `54-show-policies.sh [env]` | Show trust domain, server group/CA, components, node group template and policies |
| `55-full-test.sh` | 9-case allow/deny test matrix |
| `56-script-test.sh [env]` | Run the step-by-step demo `swa-test.sh` inside `wl-<env>` |
| `99-cleanup.sh [local\|tenant\|all]` | Remove workload containers, k3s container + volume, image and/or every tenant object of this lab |
| `azure/vm-bootstrap.sh` | **Azure**: install Docker Engine, kubectl, helm, jq…, docker group, k3s kernel modules, UFW rule (run once with sudo) |
| `azure/push-to-vm.sh` | **Azure**: run on your workstation – copy the lab, SWA bundle and conjur CLI to the VM over SSH |
| `azure/install-autostart.sh` | **Azure** (optional): systemd unit `swa-lab` that runs `51-lab-start.sh` after a VM boot / deallocate |
| `swa-go-test/` | Go client source + `build.sh` (builds in `golang:1.24`; `VERSION=x.y ./build.sh`) |
| `image/` | `Dockerfile`, `entrypoint.sh` (agent restart loop), `swa-test.sh` (demo script) |

Runtime data lives in `state/` (`k3s.kubeconfig`; per env: x509pop CA, registered JWKS, `authn_id`, agent cert) — git-ignored.
Cluster data (incl. the service-account signing key) lives in the docker volume `swa-k3s`.

## 7. Run the demo

```bash
./51-lab-start.sh                     # if the lab was stopped
./54-show-policies.sh                 # what the tenant enforces per environment
./56-script-test.sh prod              # step by step: caller, JWT-SVID, JWKS, authn-jwt, secret read
SHOW_JWT=1 ./56-script-test.sh dev    # also print the raw JWT-SVID (bearer token, ~5 min)
SHOW=1 ./56-script-test.sh prod       # print secret values in full (masked by default)
./55-full-test.sh                     # allow/deny matrix
./52-lab-stop.sh                      # stop when not in use
```

Manual calls inside a workload container:

```bash
docker exec --user swa-demo-sa wl-prod swa-go-test -sm "$SWA_API_BASE/api" -authn swa-prod <SAFE_POLICY>/<account>/username
docker exec --user swa-demo-sa wl-prod /opt/swa/bin/swa-agent api fetch jwt -a conjur -s /run/swa-agent/api.sock
```

Expected test matrix (`55-full-test.sh`):

| Case | Expected | Reason when denied |
|---|---|---|
| wl-prod / swa-demo-sa / client / prod secret | OK | |
| wl-prod / swa-demo-sa / client / dev secret | DENY | HTTP 404 — no permission on the variable |
| wl-dev / swa-demo-sa / client / dev secret | OK | |
| wl-dev / swa-demo-sa / client / prod secret | DENY | HTTP 404 |
| prod JWT sent to `authn-jwt/swa-dev` | DENY | authenticate 401 — other trust domain/issuer |
| wl-prod / root / client | DENY | no matching registration policy (user) |
| wl-prod / swa-demo-sa / `swa-agent` CLI | OK | allowed by policy element 2 (demo); DENY once element 2 is removed |
| wl-prod / root / `swa-agent` CLI | DENY | no matching registration policy (user) |
| wl-prod / swa-demo-sa / client copy with 1 byte changed | DENY | no matching registration policy (sha256) |

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| `permission denied ... docker.sock` | log out/in after `vm-bootstrap.sh` (docker group), or `newgrp docker` |
| `k3s node not Ready` + `docker logs swa-k3s` shows *cgroup v1 ... unsupported* | use Ubuntu 22.04/24.04 (cgroup v2) |
| `tenant reachable ... HTTP 000` | outbound 443 blocked (NSG outbound rule, Azure Firewall, proxy) or DNS |
| agent log `connection refused` to `172.17.0.1:18443` | `docker port swa-k3s`; UFW active without the docker0 rule → rerun `sudo ./azure/vm-bootstrap.sh` |
| `admin token missing/expired` | `./01-get-token.sh` (tokens are short-lived) |
| `swa-server not ready` | `kubectl -n swa-prod logs deploy/swa-server` (KUBECONFIG is set by `config.env`: `source config.env` first) |
| after VM restart nothing answers | `./51-lab-start.sh`, or install the autostart unit (4.5) |

## 9. Operations and notes

- **Rebuilding `swa-go-test` changes its hash.** Re-run `./10-tenant-setup.sh <env>` (it PATCHes the policy),
  `./30-build-image.sh`, `./31-workload-run.sh <env>` (10 restarts the server deployment so the policy applies at once).
- **Server restart** regenerates the server's internal CA; agents re-establish trust by themselves
  (the entrypoint restarts the agent if it exits).
- **Server authentication**: the server presents its projected k3s service-account token (aud `conjur`, 1 h,
  rotated by k3s). The tenant cannot reach the k3s API, so `10` registers the k3s JWKS inline. The signing key is
  kept in the `swa-k3s` volume; if the volume is recreated (`99-cleanup.sh local`), rerun `10` (re-registers the
  component, new `authn_id`) and `20`.
- **kubectl / helm**: `export KUBECONFIG=$PWD/state/k3s.kubeconfig` (config.env does this for the scripts), e.g.
  `kubectl -n swa-prod logs deploy/swa-server`. Or `docker exec swa-k3s kubectl ...`.
- **Host gateway**: auto-detected (Docker `bridge` gateway, else podman network gateway); set `HOST_GW` to override.
- **Secret permissions** are granted per variable with `!permit` in `SAFE_POLICY`, not via the safe's consumers group.
- **Several lab hosts on one tenant**: set a different `LAB_ID` in each host's `config.env` (e.g. `lab2`).
  Trust domains become `prod.lab2.swa.<BASE_DOMAIN>` and workload authenticators `authn-jwt/swa-prod-lab2`, so
  setup, tests and cleanup on one host never touch the other. Leave it empty for a single lab.
- **Move the lab to another host**: copy this directory (without `state/`, `.token`, `config.env`), extract the bundle,
  create `config.env` and follow section 4. The client is rebuilt from source, so its hash may differ — the policy
  always uses the hash of the binary just built.
- **Security limits (demo)**: x509pop CA keys sit in `state/`, the k3s signing key in the `swa-k3s` volume, and
  k3s runs as a privileged container; root on a node can alter binaries
  (a new hash is denied unless the tenant policy is changed too); policy element 2 lets any script of
  `swa-demo-sa` that calls the agent CLI get a JWT — remove it after the demo.

## 10. Clean up

```bash
./99-cleanup.sh local     # workload containers, k3s container + volume, workload image
./99-cleanup.sh tenant    # permissions, authenticators, node groups, components, server groups, trust domains
./99-cleanup.sh all       # both + shred keys and remove state/
```
