# Test Deployment Guide

A hands-on walkthrough to deploy and test the modernized Carbyne Stack on two kind clusters (`apollo`, `starbuck`) using the container images published to Docker Hub account `deadstrider`. It condenses [platform-setup.md](platform-setup.md) and [stack-deployment.md](stack-deployment.md) into one ordered list of commands and adds what to check after each step.

> **Status — read first.** Nothing below the platform layer has been run by the author. What *was* executed: MetalLB, Istio, Knative (with upstream, **unpatched** manifests), the Zalando operator and the stack database release on one cluster. The **patched Knative build, the Docker Hub images in this guide, the second cluster, and the whole stack** are untested. Please report failures with the output of the commands marked ▶ **Check**. [CHANGES.md](CHANGES.md) lists the known risks.

## Images used

| Component | Image (default in the Helmfiles) | Notes |
|---|---|---|
| Castor | `docker.io/deadstrider/castor-service:0.1.2-go` | Go port, used with the published Castor chart 0.4.0 |
| Amphora | `docker.io/deadstrider/amphora-service:0.1.2-go` | Go port, published Amphora chart 0.3.1 |
| Ephemeral discovery | `docker.io/deadstrider/ephemeral-discovery:0.1.2-go` | Go |
| Ephemeral network controller | `docker.io/deadstrider/ephemeral-network-controller:0.1.2-go` | Go |
| Klyshko operator | `docker.io/deadstrider/klyshko-operator:0.1.2-go` | Go, modernized |
| Thymus policy catalogue | `docker.io/deadstrider/thymus-policy-catalogue:0.1.2-go` | Go |
| Knative Serving (patched, v1.23.0) | `docker.io/deadstrider/{activator,autoscaler,controller,queue,webhook,default-domain,…}-<hash>@sha256:…` | pinned by digest in `serving/v1.23.0-multiport/serving-core.yaml` |
| Ephemeral (MPC engine) | `ghcr.io/carbynestack/ephemeral/ephemeral:0.3.1` | **Upstream image kept.** The Go `ephemeral` build contains no MP-SPDZ runtime and cannot execute MPC programs, so it was deliberately not wired in |
| Klyshko provisioner / generator, MinIO, etcd, Redis, Ory, Stackable OPA | upstream | unchanged |

Each image can be overridden with `<NAME>_IMAGE_REGISTRY`, `<NAME>_IMAGE_REPOSITORY`, `<NAME>_IMAGE_TAG` (e.g. `CASTOR_IMAGE_TAG`; the Klyshko operator uses `KLYSHKO_OPERATOR_IMAGE_*`, Thymus `THYMUS_IMAGE_*`), see `deployments/helmfile.d`. Set `CASTOR_IMAGE_REGISTRY=ghcr.io CASTOR_IMAGE_REPOSITORY=carbynestack/castor-service CASTOR_IMAGE_TAG=0.3.0` to fall back to the original Java image, which is the quickest way to find out whether a problem comes from the Go image or from the platform.

The Docker Hub repositories are created by the push; check on hub.docker.com that they are **public**, otherwise the clusters cannot pull them (or create an image pull secret and set `IMAGE_PULL_SECRET`).

## 0. Prerequisites

Tools as in the [platform guide](platform-setup.md#prerequisites): Docker, kind v0.33.0, kubectl v1.37.x, Helm v3.22.1, Helmfile v1.8.2, openssl, python3. About 8 GB of free RAM for two clusters with the full stack (3 GB per cluster is the minimum for the platform alone).

> **Existing clusters:** if you still have kind clusters called `apollo` / `starbuck` from the old setup (Kubernetes v1.26), delete them (`kind delete cluster --name apollo`) or this guide's `create` commands fail.

Raise inotify limits if pods crash with `too many open files` (see platform guide, Troubleshooting).

```bash
git clone <this repository> && cd carbynestack     # or cd into your checkout
export RELEASE_NAME=cs
```

## 1. Clusters

```bash
kind create cluster --name apollo   --image kindest/node:v1.37.0
kind create cluster --name starbuck --image kindest/node:v1.37.0
docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'   # expect 172.18.0.0/16
```

If your kind network is not `172.18.0.0/16`, change the MetalLB pools and all `172.18.x` addresses below accordingly.

## 2. Serve the patched Knative manifests

The patched Knative Serving manifests are in `serving/v1.23.0-multiport/`. The Knative Operator in the clusters downloads them over HTTP; serve them from the host in a **separate terminal and keep it running** until Knative is installed on both clusters (and during later Knative upgrades):

```bash
scripts/serve-serving-manifests.sh
# prints: SERVING_MANIFEST_BASE_URL=http://172.18.0.1:8000
```

In your working terminal:

```bash
export SERVING_MANIFEST_BASE_URL=http://172.18.0.1:8000    # use the printed value
```

▶ **Check** (from the kind network): `docker run --rm --network kind --entrypoint sh badouralix/curl-jq:alpine -c "curl -sS -o /dev/null -w '%{http_code}\n' $SERVING_MANIFEST_BASE_URL/serving-core.yaml"` prints `200` (this was verified by the author for `172.18.0.1`; a host firewall can block it).

## 3. Platform on each cluster

Run the block once for `apollo` and once for `starbuck` with the values from the table.

| | `apollo` | `starbuck` |
|---|---|---|
| `METALLB_ADDRESS_POOL` | `172.18.1.128/25` | `172.18.2.128/25` |
| `TLS_SECRET_NAME` | `apollo-tls-secret-generic` | `starbuck-tls-secret-generic` |

```bash
export CLUSTER=apollo METALLB_ADDRESS_POOL=172.18.1.128/25 TLS_SECRET_NAME=apollo-tls-secret-generic
kubectl config use-context kind-$CLUSTER

helmfile -f platform/helmfile.d/0010.metallb.yaml.gotmpl sync
helmfile -f platform/helmfile.d/0020.istio.yaml.gotmpl sync
kubectl label namespace default istio-injection=enabled --overwrite

export EXTERNAL_IP=$(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $EXTERNAL_IP        # 172.18.1.128 (apollo) / 172.18.2.128 (starbuck)

helmfile -f platform/helmfile.d/0030.knative.yaml.gotmpl sync
kubectl wait knativeserving/knative-serving -n knative-serving --for=condition=Ready --timeout=600s
helmfile -f platform/helmfile.d/0040.postgres-operator.yaml.gotmpl sync
```

▶ **Check** (both clusters), the checklist of the [platform guide](platform-setup.md#verification), plus:

```bash
kubectl get pods -n knative-serving -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}' | cut -c1-140
# activator/autoscaler/controller/webhook must run images from docker.io/deadstrider/…, net-istio-* from gcr.io/knative-releases
kubectl get knativeserving -n knative-serving -o jsonpath='{.items[0].status.version}{"\n"}'     # 1.23.0
```

If `KnativeServing` stays not `Ready`: `kubectl get knativeserving -n knative-serving knative-serving -o yaml` (conditions) and `kubectl logs -n knative-operator deploy/knative-operator`. Typical causes: manifest server unreachable (step 2), Docker Hub pull failures (private repos or rate limit).

**Multi-port smoke test of the patch (optional but recommended).** A Knative Service with two containers each exposing a port is rejected by upstream Knative and accepted by the patched build:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata: {name: multiport, namespace: default}
spec:
  template:
    spec:
      containers:
        - image: docker.io/library/nginx:alpine
          ports: [{containerPort: 80}]
        - image: docker.io/library/nginx:alpine
          name: second
          ports: [{containerPort: 8081}]
EOF
kubectl get ksvc multiport          # READY should become True (no validation error on apply)
kubectl delete ksvc multiport
```

(The second nginx listens on 80, not 8081, so its readiness is not meaningful; what is being tested is that the API accepts the Service. If it is rejected with `more than one container port`, the patched webhook is not in use.)

## 4. Stack configuration and TLS

```bash
cd deployments
export APOLLO_IP=172.18.1.128   APOLLO_FQDN=172.18.1.128.sslip.io
export STARBUCK_IP=172.18.2.128 STARBUCK_FQDN=172.18.2.128.sslip.io
export PARTNER_COUNT=2 PARTNER_FQDN_0=$APOLLO_FQDN PARTNER_FQDN_1=$STARBUCK_FQDN
export ETCD_MASTER_URL=$APOLLO_FQDN ETCD_MASTER_IP=$APOLLO_IP
export RELEASE_NAME=cs NO_SSL_VALIDATION=true TLS_ENABLED=true PROTOCOL=https
```

Create the certificates and secrets exactly as in [stack-deployment.md, step 4](stack-deployment.md#tls) (certificates in `certs/`, secrets `apollo-tls-secret-generic` / `starbuck-tls-secret-generic` in `istio-system`, copied to `knative-serving` and `default`).

▶ **Check:** `kubectl get secret -n istio-system,knative-serving,default | grep tls-secret-generic` shows the secret in all three namespaces on each cluster, and the Knative gateway already references it:

```bash
kubectl get gateway.networking.istio.io knative-ingress-gateway -n knative-serving -o jsonpath='{.spec.servers[0].tls}'
```

## 5. Deploy the Virtual Cloud Providers

`starbuck` first, then `apollo` (etcd and Castor master run on apollo):

```bash
export PLAYER_ID=1 TLS_SECRET_NAME=starbuck-tls-secret-generic
kubectl config use-context kind-starbuck
helmfile sync --set thymus.users.enabled=true

export PLAYER_ID=0 TLS_SECRET_NAME=apollo-tls-secret-generic
kubectl config use-context kind-apollo
helmfile sync --set thymus.users.enabled=true
```

Pull times are long on first run (Spilo is 1.6 GB). To watch: `kubectl get pods -w`. To save bandwidth, `kind load docker-image` the images once into both clusters.

If a release fails, deploy the Helmfiles one at a time to find the failing component (`helmfile -f helmfile.d/0100.castor.yaml.gotmpl sync`, …) in the order of the file numbers: `0010` dbms, `0020` minio, `0030` istio, `0040` etcd (apollo only), `0050` redis, `0080` thymus, `0100` castor, `0200` amphora, `0300` ephemeral, `0400` klyshko, `0450` klyshko-config.

## 6. Verify

For both clusters:

```bash
helmfile status
kubectl get pods                     # all Ready / Completed
kubectl get postgresql               # Running
kubectl get ksvc                     # Ephemeral's Knative service Ready=True (needs the patched Knative)
kubectl get pods -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[*].image | grep deadstrider
```

Expected: the castor, amphora, ephemeral-discovery, network-controller, klyshko-operator and policy-catalogue pods use the `deadstrider/*:0.1.0-go` images. Further checks:

```bash
kubectl logs deploy/cs-castor -c castor        # or the castor pod; look for startup errors, DB migration, listening on 10100
kubectl logs deploy/cs-amphora
kubectl get cm,secret | grep -i klyshko        # vcp config, engine params
kubectl logs -l control-plane=controller-manager -c manager | tail   # Klyshko operator (label from the chart)
```

Cross-VCP checks (the original guides stop at pod readiness):

* etcd reachable from starbuck: from a pod on starbuck, `nc -vz $ETCD_MASTER_IP 2379`.
* Castor master/slave link: on apollo `kubectl logs` of Castor shows requests from the slave; on starbuck it should not report connection errors to `${APOLLO_FQDN}`.
* Klyshko generates tuples with the default (fake) generator: after a few minutes `kubectl get tuplegenerationjobs` (or `kubectl get jobs`) shows jobs, and Castor's telemetry (`curl -k https://<fqdn>/castor/intra-vcp/telemetry` as configured by the chart) shows available tuples growing.

These commands are suggestions derived from the charts and have not been run; adapt label/resource names to what `kubectl get` shows.

## 7. Reporting back / known risks

* **Go images with the published charts.** The Castor/Amphora charts 0.4.0/0.3.1 were written for the Java images. The Go services are intended as drop-in replacements (same environment variables and ports), which has been checked against their own parity suites and the migrated charts, **not** against these published charts. If a pod crash-loops, `kubectl logs` and compare with the env vars in the chart; switch that component back to the Java image (section "Images used") to isolate it.
* **Klyshko operator** was tested with the migrated chart, not the published `klyshko` 0.4.0 chart.
* **Ephemeral** runs the upstream image; its discovery and network-controller are Go images. MPC execution across two clusters was never run.
* **Thymus/OPA:** Stackable OPA operator 24.7.0 on Kubernetes 1.37 is untested.
* **Postgres v2 operator:** `scram-sha-256` is the default; services connecting with the secrets were not tested against it.

## 8. Teardown

```bash
for var in apollo starbuck; do kubectl config use-context kind-$var; (cd deployments && helmfile destroy); done
kind delete cluster --name apollo
kind delete cluster --name starbuck
```

Stop the manifest server (Ctrl-C in its terminal).
