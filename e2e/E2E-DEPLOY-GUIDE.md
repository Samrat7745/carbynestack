# End-to-End Deployment, Step by Step (Go services 0.1.3-go)

This guide deploys a two-party Carbyne Stack Virtual Cloud on two kind
clusters and runs the Millionaires' test with the Carbyne Stack CLI. It starts
from an empty machine: section 1 fetches the tools, the deployment
repository, the CLI and (optionally) the images. Every command is written out;
run them one by one in the order given.

It was executed like this on 2026-11-17 and passed:

```text
PASS: 177 < 151 -> got '0' expected '0' (4s, result a403e6e5-4d24-4d00-aecc-51de8e862ae0)
PASS: 177 < 179 -> got '1' expected '1' (3s, result b67da661-0761-440c-a901-40ba98d9d0c3)
PASS: 151 < 151 -> got '0' expected '0' (3s, result d2ae9668-e68f-4b15-a143-d99a5b7a74fc)
```

Total time is about 40 minutes after the downloads: 2 minutes for the
clusters, 7 for the platform, 13 for the stacks, a few minutes for tuple
generation, then the login and the test.

## Contents

0. [What comes from where](#0-what-comes-from-where)
1. [Get everything](#1-get-everything)
2. [Before you start](#2-before-you-start)
3. [Create the clusters](#3-create-the-clusters-about-2-minutes)
4. [Serve the patched Knative manifests](#4-serve-the-patched-knative-manifests)
5. [Platform](#5-platform-about-35-minutes-per-cluster)
6. [TLS certificates and secrets](#6-tls-certificates-and-secrets-a-few-seconds)
7. [Deploy the stacks](#7-deploy-the-stacks-6-to-7-minutes-per-cluster)
8. [Tuple generation](#8-tuple-generation-a-few-minutes)
9. [Register the CLI's OAuth2 client](#9-register-the-clis-oauth2-client-in-hydra)
10. [Configure the CLI](#10-configure-the-cli)
11. [Log in](#11-log-in)
12. [Millionaires' test](#12-millionaires-test)
13. [If something fails](#13-if-something-fails)
14. [Teardown](#14-teardown)
- [Appendix A: build the images from source](#appendix-a-build-the-images-from-source)

## 0. What comes from where

| What | Source |
| --- | --- |
| Helmfiles, platform charts, patched Knative manifests, Millionaires program and script | [`Samrat7745/carbynestack`](https://github.com/Samrat7745/carbynestack), branch `go-migration` |
| Go service images | Docker Hub, account `deadstrider`, tag `0.1.3-go` (public, pulled by the clusters) |
| Patched Knative Serving images | Docker Hub, `deadstrider/*`, digest-pinned in the deployment repository |
| Carbyne Stack CLI 0.6.0 | official release [`carbynestack/cli` v0.6.0](https://github.com/carbynestack/cli/releases/tag/cli-v0.6.0) (there is no fork of the CLI) |
| Go service sources (only to rebuild images, appendix A) | `Samrat7745/{castor,amphora,ephemeral,klyshko,thymus}`, branch `go-migration` |
| Shared Go libraries (fetched by `go build` automatically) | `Samrat7745/java-http-client` (branch `feat/go-migration`), `Samrat7745/mp-spdz-integration`, `Samrat7745/common` (branch `go-migration`) |
| Upstream images (Ephemeral MPC engine, Klyshko generator, Postgres, Ory, OPA, ...) | their public registries, pulled by the clusters |

### Overview of the deployment

| | Player 0 | Player 1 |
| --- | --- | --- |
| kind cluster | `it0` | `it1` |
| kubeconfig | `$WORK/it0.kubeconfig` | `$WORK/it1.kubeconfig` |
| Istio ingress IP | `172.18.5.128` | `172.18.6.128` |
| Host name | `172.18.5.128.sslip.io` | `172.18.6.128.sslip.io` |
| MetalLB pool | `172.18.5.128/25` | `172.18.6.128/25` |
| TLS secret | `it0-tls-secret-generic` | `it1-tls-secret-generic` |
| CLI provider id | `1` | `2` |

Every `kubectl` and `helmfile` command uses the kubeconfig of one cluster
(the `vcp` helper in step 2.4 switches it), so your default kube context is
never changed.

### Images

| Component | Image |
| --- | --- |
| Castor | `docker.io/deadstrider/castor-service:0.1.3-go` |
| Amphora | `docker.io/deadstrider/amphora-service:0.1.3-go` |
| Ephemeral discovery | `docker.io/deadstrider/ephemeral-discovery:0.1.3-go` |
| Ephemeral network controller | `docker.io/deadstrider/ephemeral-network-controller:0.1.3-go` |
| Klyshko operator | `docker.io/deadstrider/klyshko-operator:0.1.3-go` |
| Thymus policy catalogue | `docker.io/deadstrider/thymus-policy-catalogue:0.1.3-go` |
| Ephemeral MPC engine | `ghcr.io/carbynestack/ephemeral/ephemeral:0.3.1` (upstream) |
| Knative Serving 1.23 (multi-port patch) | `docker.io/deadstrider/*`, digest-pinned |

These are the defaults of the Helmfiles on branch `go-migration`; nothing has
to be overridden.

## 1. Get everything

All downloads go into one working directory, `WORK`. The examples use
`~/build-tmp`, which already holds the files of earlier runs on this machine;
on a new machine any empty directory works.

```bash
export WORK=$HOME/build-tmp
mkdir -p $WORK $HOME/bin
```

### 1.1 Prerequisites that are not downloaded here

Docker (with your user in the `docker` group), Java 17, `git`, `curl`, `jq`,
`openssl`, `python3`. Check:

```bash
docker version --format '{{.Server.Version}}'    # 29.x was used
java -version 2>&1 | head -1                     # 17
git --version; curl --version | head -1; jq --version; openssl version
```

On Ubuntu, missing ones come from `sudo apt install openjdk-17-jre-headless jq git curl openssl`.

### 1.2 Tools (kind, kubectl, Helm 3, Helmfile)

These are the latest releases as of 2026-11-17 (Helm 3.22.1 is the latest
Helm 3). Skip a tool if `which` already finds the right version. kind, kubectl and
Helmfile go to `~/bin`; Helm 3 goes into `$WORK/helm3`. It is put first on the
`PATH` in step 2.4, so an installed Helm 4 stays untouched (the Helmfiles were
written for Helm 3).

```bash
cd $HOME/bin

# kind v0.33.0
curl -fsSLo kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64 && chmod +x kind

# kubectl v1.37.2
curl -fsSLo kubectl https://dl.k8s.io/release/v1.37.2/bin/linux/amd64/kubectl && chmod +x kubectl

# Helmfile 1.8.4
curl -fsSL https://github.com/helmfile/helmfile/releases/download/v1.8.4/helmfile_1.8.4_linux_amd64.tar.gz \
  | tar -xz helmfile

# Helm v3.22.1 (into $WORK/helm3/linux-amd64/helm)
mkdir -p $WORK/helm3
curl -fsSL https://get.helm.sh/helm-v3.22.1-linux-amd64.tar.gz | tar -xz -C $WORK/helm3

# empty Helm plugin directory (keeps Helm 4 plugins away from Helm 3)
mkdir -p $WORK/hp-none
```

Put `~/bin` on the `PATH` of every new terminal. zsh does not read
`~/.profile` (which adds `~/bin` for bash), so without this line `kind`,
`kubectl` and `helmfile` are reported as "command not found":

```bash
grep -q 'export PATH="$HOME/bin:$PATH"' ~/.zshrc || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

▶ **Check:**

```bash
$HOME/bin/kind version                       # kind v0.33.0 ...
$HOME/bin/kubectl version --client           # Client Version: v1.37.2
$HOME/bin/helmfile --version                 # helmfile version 1.8.4
$WORK/helm3/linux-amd64/helm version --short # v3.22.1+...
```

### 1.3 Deployment repository from your GitHub

```bash
cd $WORK
git clone -b go-migration https://github.com/Samrat7745/carbynestack.git
export CS=$WORK/carbynestack
cd $CS && git log --oneline -1
```

If the clone already exists, update it instead:

```bash
cd $WORK/carbynestack && git fetch origin && git checkout go-migration && git pull
```

This guide uses `CS=$WORK/carbynestack`. On this machine the same repository
is also checked out at
`~/workspace/Go_migration/go_versions/carbynestack` (branch `main`,
tracking `origin/go-migration`); either checkout works if it is up to date.

▶ **Check** that the parts this guide needs are there:

```bash
ls $CS/platform/helmfile.d $CS/deployments/helmfile.d
ls $CS/serving/v1.23.0-multiport            # serving-core.yaml  serving-crds.yaml
ls $CS/e2e                                  # billionaires.mpc  mill.sh  E2E-DEPLOY-GUIDE.md
ls $CS/scripts                              # serve-serving-manifests.sh  klyshko-postrender.sh ...
grep -h 'default "0.1.3-go"' $CS/deployments/helmfile.d/*.gotmpl | wc -l   # 6
```

### 1.4 Carbyne Stack CLI

```bash
mkdir -p $WORK/cli && cd $WORK/cli
curl -fsSLO https://github.com/carbynestack/cli/releases/download/cli-v0.6.0/cli-0.6.0.jar
echo "75e7256a2ea134a7446851699d43051987ce562b062fc30ab01b06d3a2d08421  cli-0.6.0.jar" | sha256sum -c -
# cli-0.6.0.jar: OK
```

### 1.5 Images (optional pre-pull)

The clusters pull all images themselves; nothing has to be done. Pre-pulling
the six Go service images only lets you check now that Docker Hub serves them
(and later lets you load them into the clusters without a second download,
step 3):

```bash
for n in castor-service amphora-service ephemeral-discovery ephemeral-network-controller \
         klyshko-operator thymus-policy-catalogue; do
  docker pull -q docker.io/deadstrider/$n:0.1.3-go
done
docker pull -q kindest/node:v1.37.0
```

If a pull fails with `unauthorized` or `not found`, check on hub.docker.com
that the repository is public.

## 2. Before you start

### 2.1 Existing clusters

If clusters `it0` / `it1` exist from an earlier run, delete them first:

```bash
$HOME/bin/kind get clusters
$HOME/bin/kind delete cluster --name it0
$HOME/bin/kind delete cluster --name it1
```

### 2.2 Host limits

kind nodes need inotify instances. With the default limit (128) a third or
fourth kind cluster on this machine does not boot (`kind create` fails with
`could not find a log line that matches "Reached target .*Multi-User
System.*"`). Two clusters on an otherwise empty machine worked with 128, but
raise the limit anyway if you can:

```bash
sudo sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=524288
```

Permanent (survives a reboot):

```bash
printf 'fs.inotify.max_user_instances=1024\nfs.inotify.max_user_watches=524288\n' \
  | sudo tee /etc/sysctl.d/99-kind.conf
```

### 2.3 Memory

Both stacks together use about 6 GB. Check that at least 8 GB are available:

```bash
free -m      # "available" column
```

### 2.4 Shell setup

You need **two terminals**. Terminal 2 only runs the manifest server in step
4. Run everything else in terminal 1, starting with this block. If you open a
new terminal later, run this block again:

```bash
export WORK=$HOME/build-tmp
export CS=$WORK/carbynestack
# Helm 3 first on the PATH, then kind/kubectl/helmfile from ~/bin
export PATH=$WORK/helm3/linux-amd64:$HOME/bin:/usr/bin:$PATH
export HELM_PLUGINS=$WORK/hp-none
export RELEASE_NAME=cs
export IP0=172.18.5.128 IP1=172.18.6.128

# switch the current shell to one cluster: vcp it0 | vcp it1
vcp() {
  export KUBECONFIG=$WORK/$1.kubeconfig
  export HELM_CACHE_HOME=$WORK/helm-$1/cache
  export HELM_CONFIG_HOME=$WORK/helm-$1/config
  export HELM_DATA_HOME=$WORK/helm-$1/data
  echo "now on $1"
}
```

▶ **Check:**

```bash
helm version --short          # v3.22.1+...   (must be Helm 3)
helmfile --version            # helmfile version 1.8.4
kind version                  # kind v0.33.0 ...
kubectl version --client      # Client Version: v1.37.2
```

## 3. Create the clusters (about 2 minutes)

```bash
kind create cluster --name it0 --image kindest/node:v1.37.0 --kubeconfig $WORK/it0.kubeconfig
kind create cluster --name it1 --image kindest/node:v1.37.0 --kubeconfig $WORK/it1.kubeconfig
```

▶ **Check:**

```bash
kind get clusters             # it0, it1
vcp it0; kubectl get nodes    # it0-control-plane   Ready
vcp it1; kubectl get nodes    # it1-control-plane   Ready  (may say NotReady for ~20 s)
docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{.Gateway}} {{end}}'
# ... 172.18.0.0/16 172.18.0.1
```

If the subnet is not `172.18.0.0/16`, every `172.18.x` address in this guide
has to be changed accordingly.

Optional, if you pre-pulled the images in step 1.5: load them into both
clusters so they are not downloaded again.

```bash
for c in it0 it1; do
  for n in castor-service amphora-service ephemeral-discovery ephemeral-network-controller \
           klyshko-operator thymus-policy-catalogue; do
    kind load docker-image docker.io/deadstrider/$n:0.1.3-go --name $c
  done
done
```

## 4. Serve the patched Knative manifests

The Knative operator downloads the patched Serving manifests over HTTP from
the host. In **terminal 2**:

```bash
cd $HOME/build-tmp/carbynestack        # = $CS
scripts/serve-serving-manifests.sh
```

It prints `SERVING_MANIFEST_BASE_URL=http://172.18.0.1:8000` and keeps
running. Leave it running until step 5 is finished on both clusters.

Back in **terminal 1**:

```bash
export SERVING_MANIFEST_BASE_URL=http://172.18.0.1:8000
```

▶ **Check** (both print `200`):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' $SERVING_MANIFEST_BASE_URL/serving-core.yaml
docker run --rm --network kind --entrypoint sh badouralix/curl-jq:alpine \
  -c "curl -sS -o /dev/null -w '%{http_code}\n' $SERVING_MANIFEST_BASE_URL/serving-crds.yaml"
```

## 5. Platform (about 3.5 minutes per cluster)

### 5.1 Player 0 (`it0`)

```bash
cd $CS
vcp it0
export METALLB_ADDRESS_POOL=172.18.5.128/25
export TLS_SECRET_NAME=it0-tls-secret-generic
```

MetalLB:

```bash
helmfile -f platform/helmfile.d/0010.metallb.yaml.gotmpl sync
```

Istio:

```bash
helmfile -f platform/helmfile.d/0020.istio.yaml.gotmpl sync
kubectl label namespace default istio-injection=enabled --overwrite
```

Wait for the ingress IP and remember it:

```bash
until kubectl get svc -n istio-system istio-ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -q .; do sleep 3; done
export EXTERNAL_IP=$(kubectl get svc -n istio-system istio-ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $EXTERNAL_IP             # 172.18.5.128
```

Knative (uses `SERVING_MANIFEST_BASE_URL`, `EXTERNAL_IP` and
`TLS_SECRET_NAME`):

```bash
helmfile -f platform/helmfile.d/0030.knative.yaml.gotmpl sync
kubectl wait knativeserving/knative-serving -n knative-serving --for=condition=Ready --timeout=600s
```

Postgres operator:

```bash
helmfile -f platform/helmfile.d/0040.postgres-operator.yaml.gotmpl sync
kubectl rollout status deploy/postgres-operator --timeout=300s
```

If a `helmfile ... sync` fails with a download timeout or `context deadline
exceeded`, run the same command again.

### 5.2 Player 1 (`it1`)

The same commands with the player 1 values:

```bash
cd $CS
vcp it1
export METALLB_ADDRESS_POOL=172.18.6.128/25
export TLS_SECRET_NAME=it1-tls-secret-generic

helmfile -f platform/helmfile.d/0010.metallb.yaml.gotmpl sync
helmfile -f platform/helmfile.d/0020.istio.yaml.gotmpl sync
kubectl label namespace default istio-injection=enabled --overwrite

until kubectl get svc -n istio-system istio-ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -q .; do sleep 3; done
export EXTERNAL_IP=$(kubectl get svc -n istio-system istio-ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $EXTERNAL_IP             # 172.18.6.128

helmfile -f platform/helmfile.d/0030.knative.yaml.gotmpl sync
kubectl wait knativeserving/knative-serving -n knative-serving --for=condition=Ready --timeout=600s

helmfile -f platform/helmfile.d/0040.postgres-operator.yaml.gotmpl sync
kubectl rollout status deploy/postgres-operator --timeout=300s
```

### 5.3 Check the platform

On each cluster (`vcp it0`, then `vcp it1`):

```bash
kubectl get knativeserving -n knative-serving -o jsonpath='{.items[0].status.version}{"\n"}'
# 1.23.0
kubectl get pods -n knative-serving \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}' | cut -c1-110
# activator / autoscaler / controller / webhook: docker.io/deadstrider/...
kubectl get pods -A | grep -vE 'Running|Completed'
# only the header line
```

You can now stop the manifest server in terminal 2 (Ctrl-C).

## 6. TLS certificates and secrets (a few seconds)

Each player gets a self-signed certificate for its host name and IP. Each
secret also carries the partner's certificate as `cacert`, which the MPC mTLS
link between the players uses.

Create the certificates:

```bash
mkdir -p $WORK/certs2 && cd $WORK/certs2
openssl req -x509 -newkey rsa:2048 -keyout it0.key -out it0.crt -days 30 -nodes \
  -subj "/CN=$IP0.sslip.io" -addext "subjectAltName=DNS:$IP0.sslip.io,IP:$IP0"
openssl req -x509 -newkey rsa:2048 -keyout it1.key -out it1.crt -days 30 -nodes \
  -subj "/CN=$IP1.sslip.io" -addext "subjectAltName=DNS:$IP1.sslip.io,IP:$IP1"
```

Secrets on player 0 (own key and certificate, partner certificate `it1.crt`):

```bash
vcp it0
for ns in istio-system knative-serving default; do
  kubectl create secret generic it0-tls-secret-generic -n $ns \
    --from-file=tls.key=it0.key --from-file=tls.crt=it0.crt --from-file=cacert=it1.crt \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

Secrets on player 1 (partner certificate `it0.crt`):

```bash
vcp it1
for ns in istio-system knative-serving default; do
  kubectl create secret generic it1-tls-secret-generic -n $ns \
    --from-file=tls.key=it1.key --from-file=tls.crt=it1.crt --from-file=cacert=it0.crt \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

▶ **Check** on each cluster:

```bash
vcp it0
kubectl get secret -A | grep tls-secret-generic        # 3 lines
kubectl get gateway.networking.istio.io knative-ingress-gateway -n knative-serving \
  -o jsonpath='{.spec.servers[0].tls}{"\n"}'
# {"credentialName":"it0-tls-secret-generic","mode":"SIMPLE"}
```

Repeat with `vcp it1` (expect `it1-tls-secret-generic`).

## 7. Deploy the stacks (6 to 7 minutes per cluster)

### 7.1 Common configuration

```bash
cd $CS/deployments
export APOLLO_IP=$IP0 APOLLO_FQDN=$IP0.sslip.io
export STARBUCK_IP=$IP1 STARBUCK_FQDN=$IP1.sslip.io
export PARTNER_COUNT=2 PARTNER_FQDN_0=$IP0.sslip.io PARTNER_FQDN_1=$IP1.sslip.io
export ETCD_MASTER_URL=$IP0.sslip.io ETCD_MASTER_IP=$IP0
export NO_SSL_VALIDATION=true TLS_ENABLED=true PROTOCOL=https
```

`APOLLO_*` and `STARBUCK_*` are the variable names of the Helmfiles; they
mean player 0 (`it0`) and player 1 (`it1`).

### 7.2 Player 1 first

```bash
vcp it1
export PLAYER_ID=1 TLS_SECRET_NAME=it1-tls-secret-generic
helmfile sync --set thymus.users.enabled=true
```

### 7.3 Then player 0

etcd and the Castor master run on player 0:

```bash
vcp it0
export PLAYER_ID=0 TLS_SECRET_NAME=it0-tls-secret-generic
helmfile sync --set thymus.users.enabled=true
```

On the first run on a new cluster, `helmfile sync` failed once on each
cluster with `Error: context deadline exceeded`, because pulling the first
images is slow (`cs-redis` on player 1, `cs-etcd` on player 0). **Run the same
`helmfile sync` command again**; the second run completed both times.

If it keeps failing, deploy the Helmfiles one by one to find the release, in
this order (`0040.etcd` only has a release on player 0):

```bash
for f in 0010.dbms 0020.minio 0030.istio 0040.etcd 0050.redis 0080.thymus \
         0100.castor 0200.amphora 0300.ephemeral 0400.klyshko 0450.klyshko-config; do
  echo "=== $f"; helmfile -f helmfile.d/$f.yaml.gotmpl sync --set thymus.users.enabled=true || break
done
```

### 7.4 Wait until everything is ready

On each cluster:

```bash
vcp it0
kubectl get pods -A | grep -vE 'Running|Completed'     # repeat until only the header line remains
```

The last pods to start were `cs-thymus-hydra-maester` and `opa-server-default`
on player 0 (slow image pulls, about 3 minutes after the sync ended).

Restarts at start-up are expected and not errors. Castor and Amphora restarted
3 to 6 times until Postgres and MinIO were up, and player 1's
`cs-ephemeral-discovery` 6 times until player 0 was reachable. After that the
counts must stay the same:

```bash
kubectl get pods --no-headers | awk '$4!="0"{print $1, $4" restarts"}'
```

### 7.5 Check the stack

On each cluster:

```bash
vcp it0
helmfile status                                        # all releases deployed
kubectl get postgresql                                 # cs-cs-postgres-dbms ... Running
kubectl get ksvc                                       # ephemeral-generic ... True
kubectl get pods -o 'custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[*].image' \
  | grep deadstrider
# castor, amphora, ephemeral-discovery, ephemeral-network-controller,
# thymus-policy-catalogue: docker.io/deadstrider/...:0.1.3-go
kubectl get deploy klyshko-controller-manager -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
# quay.io/brancz/kube-rbac-proxy:v0.23.1 docker.io/deadstrider/klyshko-operator:0.1.3-go
```

Repeat with `vcp it1`.

## 8. Tuple generation (a few minutes)

Klyshko generates fake-offline tuples and uploads them to Castor on both
players. Its jobs are deleted when they are done, so look at Castor's
telemetry instead of the jobs.

On player 0, in terminal 1:

```bash
vcp it0
kubectl port-forward deploy/cs-castor 18100:10100 >/dev/null 2>&1 &
sleep 3
curl -s http://127.0.0.1:18100/intra-vcp/telemetry \
  | jq -r '.metrics[] | select(.available > 0) | "\(.type) \(.available)"'
kill %1
```

Expected once generation is done (it can be lower while it is running):

```text
BIT_GFP 100000
INPUT_MASK_GFP 199998
MULTIPLICATION_TRIPLE_GFP 100000
...
```

Same on player 1 (`vcp it1`, port `18101` instead of `18100`).

Continue when `INPUT_MASK_GFP` and `MULTIPLICATION_TRIPLE_GFP` are available on
both players.

## 9. Register the CLI's OAuth2 client in Hydra

The CLI logs in with the OAuth2 authorization-code flow against Hydra on each
player. Its client is not part of the Helmfiles; register it once per cluster:

```bash
vcp it0
kubectl exec deploy/cs-thymus-hydra -c hydra -- hydra create oauth2-client \
  --endpoint http://localhost:4445 \
  --name carbynestack-cli \
  --grant-type authorization_code,refresh_token \
  --response-type code \
  --scope openid,offline,email,profile \
  --redirect-uri http://127.0.0.1:32768/callback \
  --token-endpoint-auth-method none \
  --format json > $WORK/cli/oauth-client-it0.json

vcp it1
kubectl exec deploy/cs-thymus-hydra -c hydra -- hydra create oauth2-client \
  --endpoint http://localhost:4445 \
  --name carbynestack-cli \
  --grant-type authorization_code,refresh_token \
  --response-type code \
  --scope openid,offline,email,profile \
  --redirect-uri http://127.0.0.1:32768/callback \
  --token-endpoint-auth-method none \
  --format json > $WORK/cli/oauth-client-it1.json
```

▶ **Check** (each prints a UUID):

```bash
jq -r .client_id $WORK/cli/oauth-client-it0.json
jq -r .client_id $WORK/cli/oauth-client-it1.json
```

## 10. Configure the CLI

The CLI jar was downloaded in step 1.4 to `$WORK/cli/cli-0.6.0.jar`.

### 10.1 Keep the old files

```bash
cd $WORK/cli
for f in config tokens.json ts.jks; do [ -f $f ] && cp $f $f.bak-$(date +%Y%m%d-%H%M); done
```

### 10.2 Write the configuration

`prime`, `r` and `rinv` are the standard Carbyne Stack field parameters.

```bash
cd $WORK/cli
ID0=$(jq -r .client_id oauth-client-it0.json)
ID1=$(jq -r .client_id oauth-client-it1.json)
cat > config <<EOF
{
  "prime": 198766463529478683931867765928436695041,
  "r": 141515903391459779531506841503331516415,
  "rinv": 133854242216446749056083838363708373830,
  "noSslValidation": true,
  "trustedCertificates": [],
  "providers": [
    {
      "id": 1,
      "baseUrl": "https://$IP0.sslip.io/",
      "amphoraServiceUrl": "https://$IP0.sslip.io/amphora",
      "castorServiceUrl": "https://$IP0.sslip.io/castor",
      "ephemeralServiceUrl": "https://$IP0.sslip.io/",
      "thymusServiceUrl": "https://$IP0.sslip.io/iam/policies",
      "oauth2ClientId": "$ID0",
      "oauth2AuthEndpointUri": "https://$IP0.sslip.io/iam/oauth/oauth2/auth",
      "oauth2TokenEndpointUri": "https://$IP0.sslip.io/iam/oauth/oauth2/token",
      "oauth2CallbackUrl": "http://127.0.0.1:32768/callback"
    },
    {
      "id": 2,
      "baseUrl": "https://$IP1.sslip.io/",
      "amphoraServiceUrl": "https://$IP1.sslip.io/amphora",
      "castorServiceUrl": "https://$IP1.sslip.io/castor",
      "ephemeralServiceUrl": "https://$IP1.sslip.io/",
      "thymusServiceUrl": "https://$IP1.sslip.io/iam/policies",
      "oauth2ClientId": "$ID1",
      "oauth2AuthEndpointUri": "https://$IP1.sslip.io/iam/oauth/oauth2/auth",
      "oauth2TokenEndpointUri": "https://$IP1.sslip.io/iam/oauth/oauth2/token",
      "oauth2CallbackUrl": "http://127.0.0.1:32768/callback"
    }
  ]
}
EOF
jq -r '.providers[] | "\(.id) \(.baseUrl) \(.oauth2ClientId)"' config
```

### 10.3 Trust store for the login

The login's token request is made by Java and needs both cluster
certificates:

```bash
cd $WORK/cli
rm -f ts.jks
keytool -importcert -noprompt -alias it0 -file $WORK/certs2/it0.crt -keystore ts.jks -storepass changeit
keytool -importcert -noprompt -alias it1 -file $WORK/certs2/it1.crt -keystore ts.jks -storepass changeit
```

### 10.4 CLI shortcut

```bash
export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=$WORK/cli/ts.jks -Djavax.net.ssl.trustStorePassword=changeit"
cs() { java -jar $WORK/cli/cli-0.6.0.jar \
  --config-file $WORK/cli/config \
  --access-token-file $WORK/cli/tokens.json "$@"; }
```

The CLI prints `Picked up JAVA_TOOL_OPTIONS ...` and a Log4j `StatusLogger`
warning before every command; both are harmless.

▶ **Check** (both print `200`):

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://$IP0.sslip.io/iam/oauth/.well-known/openid-configuration
curl -sk -o /dev/null -w '%{http_code}\n' https://$IP1.sslip.io/iam/oauth/.well-known/openid-configuration
```

## 11. Log in

Run this on this machine; the CLI waits for the browser callback on
`127.0.0.1:32768`, so the browser has to run here too.

```bash
rm -f $WORK/cli/tokens.json
cs login
```

1. A login page opens for player 0 (`172.18.5.128.sslip.io`), then for player
   1 (`172.18.6.128.sslip.io`). Accept the self-signed certificate warning for
   each.
2. Log in with the **same user on both** players. The demo users are created
   by `thymus.users.enabled=true` (public chart defaults):

   | User | Email | Password |
   | --- | --- | --- |
   | Elon | `elon@carbynestack.io` | `2#Tv91*d-Z,M` |
   | Jeff | `jeff@carbynestack.io` | `86KIo6<]!/V=` |

3. When both callbacks have arrived, the CLI writes `tokens.json` and exits.

If the page shows `invalid_scope` or `invalid_client`, the client from step 9
is wrong; register it again and update `config` (step 10.2).

▶ **Check:**

```bash
ls -la $WORK/cli/tokens.json                 # exists, about 3.4 kB
cs castor get-telemetry 1                    # bit_gfp  available: 100000 ...
cs castor get-telemetry 2                    # same for player 1
cs amphora get-secrets                       # empty output, no error
```

## 12. Millionaires' test

The program is `$CS/e2e/billionaires.mpc` (from the deployment repository): it
compares two secret inputs and returns `1` if the first is smaller than the
second, otherwise `0`.

### 12.1 With the script

`$CS/e2e/mill.sh` plays three games. For each it creates two secrets, runs the
program on both players through Ephemeral, reads the result secret and
deletes the inputs. It uses `$WORK/cli/{cli-0.6.0.jar,config,tokens.json}`
and the `JAVA_TOOL_OPTIONS` of step 10.4, and exits with 1 if a game fails.

```bash
$CS/e2e/mill.sh | tee $WORK/cli/mill-$(date +%Y%m%d-%H%M).log
```

Expected (3 to 4 seconds per game):

```text
PASS: 177 < 151 -> got '0' expected '0' (4s, result <uuid>)
PASS: 177 < 179 -> got '1' expected '1' (3s, result <uuid>)
PASS: 151 < 151 -> got '0' expected '0' (3s, result <uuid>)
```

### 12.2 By hand, one game

```bash
A=$(cs amphora create-secret 177 -t accessPolicy=carbynestack.def -t authorizedPrograms=ephemeral-generic 2>/dev/null | tail -n1); echo $A
B=$(cs amphora create-secret 151 -t accessPolicy=carbynestack.def -t authorizedPrograms=ephemeral-generic 2>/dev/null | tail -n1); echo $B
R=$(cs ephemeral execute -t 120 -i $A -i $B ephemeral-generic.default < $CS/e2e/billionaires.mpc 2>/dev/null | tail -n1 | tr -d '[]'); echo $R
cs amphora get-secret $R                     # [0]
cs amphora delete-secrets $A $B
```

### 12.3 After the test

```bash
for c in it0 it1; do vcp $c
  for d in cs-castor cs-amphora; do
    echo "$c $d errors: $(kubectl logs deploy/$d --all-containers --since=10m | grep -ciE 'level=error|panic')"
  done
  kubectl get pods --no-headers | awk '$4!="0"{print $1, $4" restarts"}'
done
```

Expected: 0 errors, and the same restart counts as in step 7.4.

### What the test exercises

| Step | Go code under test |
| --- | --- |
| `create-secret` | Amphora (gfp conversion through the `mp-spdz-integration` library), Castor serving input masks, Amphora's Castor client built with `java-http-client` |
| `ephemeral execute` | Ephemeral discovery and network controller; the upstream MPC engine fetching tuples from Castor and secrets from Amphora |
| Reservation sharing | Castor master → slave through the peer client built with `java-http-client` |
| Tuple supply | Klyshko operator → Castor upload |
| Access checks | Thymus policy catalogue and OPA |
| `get-secret` | Amphora recombining the output shares of both players |

## 13. If something fails

Collect this and send it together with the output of the failing command:

```bash
for c in it0 it1; do vcp $c; echo "=== $c"
  kubectl get pods -A | grep -vE 'Running|Completed'
  kubectl get ksvc
  kubectl get pods --no-headers | awk '$4!="0"{print $1, $4" restarts"}'
  for d in cs-castor cs-amphora cs-ephemeral-discovery; do
    echo "-- $d"; kubectl logs deploy/$d --all-containers --tail=50 | grep -iE 'error|panic' | tail -5
  done
done
```

Common causes:

| Symptom | Cause / fix |
| --- | --- |
| `kind create` fails with "Reached target ... Multi-User System" | inotify limit, step 2.2 |
| `helm version` shows v4 | `PATH` of step 2.4 not set in this terminal |
| `helmfile sync` fails with `context deadline exceeded` | slow first image pull; run it again (step 7.3) |
| `KnativeServing` not Ready | manifest server (step 4) not running or not reachable |
| Pods in `ImagePullBackOff` for `deadstrider/*` | image not public on Docker Hub, or rate limit; step 1.5 |
| Login page `invalid_scope` / `invalid_client` | OAuth client of step 9 |
| CLI `PKIX path building failed` | `JAVA_TOOL_OPTIONS` not set or `ts.jks` missing (steps 10.3, 10.4) |
| A later game hangs | upstream SPECS-2171: delete the `ephemeral-generic` pods on both clusters and run it again |

## 14. Teardown

```bash
kind delete cluster --name it0
kind delete cluster --name it1
rm -f $WORK/it0.kubeconfig $WORK/it1.kubeconfig
```

Stop the manifest server if it still runs (Ctrl-C in terminal 2, or
`pkill -f 'http.server 8000'`).

## Appendix A: build the images from source

Only needed to change a service or to rebuild the images; the deployment
above uses the published images. The Go modules fetch the shared libraries
(`java-http-client`, `mp-spdz-integration`) from your GitHub automatically.

### A.1 Clone the service repositories

```bash
mkdir -p $WORK/src && cd $WORK/src
for r in castor amphora ephemeral klyshko thymus; do
  git clone -b go-migration https://github.com/Samrat7745/$r.git
done
```

The shared libraries, only if you want to work on them:

```bash
git clone -b feat/go-migration https://github.com/Samrat7745/java-http-client.git
git clone -b go-migration https://github.com/Samrat7745/mp-spdz-integration.git
git clone -b go-migration https://github.com/Samrat7745/common.git
```

### A.2 Build the images

Choose a new tag; `0.1.3-go` is the published one.

```bash
export TAG=0.1.4-go
cd $WORK/src
docker build -t docker.io/deadstrider/castor-service:$TAG               castor/go
docker build -t docker.io/deadstrider/amphora-service:$TAG              amphora/go
docker build -t docker.io/deadstrider/ephemeral-discovery:$TAG          -f ephemeral/build/Dockerfile.discovery ephemeral
docker build -t docker.io/deadstrider/ephemeral-network-controller:$TAG -f ephemeral/build/Dockerfile ephemeral
docker build -t docker.io/deadstrider/klyshko-operator:$TAG             klyshko/klyshko-operator
docker build -t docker.io/deadstrider/thymus-policy-catalogue:$TAG      thymus/services
```

Each build takes 1 to 2 minutes; run them one after the other.

### A.3 Use them

Either push them (`docker login` as `deadstrider`, then `docker push
docker.io/deadstrider/<name>:$TAG` for each), or load them into the clusters
without pushing:

```bash
for c in it0 it1; do
  for n in castor-service amphora-service ephemeral-discovery ephemeral-network-controller \
           klyshko-operator thymus-policy-catalogue; do
    kind load docker-image docker.io/deadstrider/$n:$TAG --name $c
  done
done
```

Then deploy (step 7) with the tag set for each component:

```bash
export CASTOR_IMAGE_TAG=$TAG AMPHORA_IMAGE_TAG=$TAG DISCOVERY_IMAGE_TAG=$TAG \
       NETWORK_CONTROLLER_IMAGE_TAG=$TAG KLYSHKO_OPERATOR_IMAGE_TAG=$TAG THYMUS_IMAGE_TAG=$TAG
```

## Known limitations

- Only the default fake-offline tuple generator is covered, not the secure
  (CowGear) generator.
- Both inputs are created by the same user; a game between two different
  logged-in users was not run.
- Castor's reservation stress test (unit tests) is flaky because of an
  occasional Postgres deadlock under a burst of simultaneous reservations. The
  three sequential games here are far below that load.
- The module paths of all Go repositories point to the forks
  (`github.com/Samrat7745/...`); they have to be changed back before merging
  upstream.
