# Platform Setup Guide

This guide describes how to prepare two [kind](https://kind.sigs.k8s.io/) Kubernetes clusters, called `apollo` and `starbuck`, that are suitable for deploying a two-party Carbyne Stack Virtual Cloud. It is the modernized version of the original Platform Setup guide: the platform components are installed with Helmfiles from `platform/` instead of ad-hoc `kubectl apply` of generated YAML, and all component versions have been upgraded.

Deploying Carbyne Stack itself on top of the platform is described in [stack-deployment.md](stack-deployment.md).

> **Validation status.** The platform steps below were executed on a single kind cluster (Kubernetes v1.37.0, Helm v3.22.1, Helmfile v1.8.2) with the results listed in [Verification status](#verification-status). Two-cluster operation (`apollo` + `starbuck` talking to each other) and the Carbyne Stack deployment on top of the platform have **not** been tested.

## Prerequisites

> **Warning:** The versions below are the ones used to develop and (partly) test this guide. Other versions may work, but are untested.

| Tool | Version | Remarks |
|---|---|---|
| [Docker Engine](https://docs.docker.com/engine/) | 29.1.3 | Complete the [post-installation steps](https://docs.docker.com/engine/install/linux-postinstall/) |
| [kind](https://kind.sigs.k8s.io/) | v0.33.0 | Provides the `kindest/node:v1.37.0` image |
| [kubectl](https://kubernetes.io/docs/reference/kubectl/) | v1.37.x | |
| [Helm](https://helm.sh/) | v3.22.1 | Helm v4.3.1 renders all Helmfiles as well (static validation only) |
| [Helmfile](https://github.com/helmfile/helmfile) | v1.8.2 | Helmfile v1 requires the `.gotmpl` file extension for templated files |
| [Helm Diff Plugin](https://github.com/databus23/helm-diff) | v3.15.15 | Only required for `helmfile diff`/`apply`, not for `sync` |

> **Info:** You need at least 3 GB of memory and 1 CPU core per kind cluster for the platform and the stack. Both clusters running at the same time need considerably more; the full stack on one cluster was not run during the validation of this guide.

Optional, for static validation only (`scripts/validate.sh`): [kubeconform](https://github.com/yannh/kubeconform) and [pluto](https://github.com/FairwindsOps/pluto). Building a patched Knative Serving (see [Knative](#knative)) additionally needs `git`, Go and [ko](https://ko.build/).

The original guide listed OpenJDK 11; none of the Helmfiles in this repository needs it.

## Component versions

| Component | Original | This repository | Installed with |
|---|---|---|---|
| Kubernetes (`kindest/node`) | v1.26.6 | v1.37.0 | `kind create cluster` |
| Istio | v1.17.0 (Istio Operator) | v1.31.3 | Helm charts `base`, `istiod`, `gateway` |
| MetalLB | v0.13.9 | v0.16.1 | Helm chart `metallb` 0.16.1 |
| Knative Serving / Operator | v1.8.2 | v1.23.0 | Helm chart `knative-operator` v1.23.0 + `KnativeServing` resource |
| net-istio | v1.8.2 | v1.23.0 | via `KnativeServing` manifests |
| net-certmanager | v1.8.2 | not installed | see [Compatibility](CHANGES.md#compatibility-issues-and-decisions) |
| Zalando Postgres Operator | v1.9.0 | v2.0.3 | Helm chart `postgres-operator` 2.0.3 |

The choice of the Zalando Postgres Operator (instead of CloudNativePG) is explained in [CHANGES.md](CHANGES.md#postgresql-operator-zalando-203-vs-cloudnativepg).

## Setting up the Clusters

### Kind Clusters

You will need two Carbyne Stack Virtual Cloud Providers deployed to separate Kubernetes clusters. The clusters are called `apollo` and `starbuck`. The `--name <name>` option makes kind create the Kubernetes context `kind-<name>`:

```bash
kind create cluster --name apollo --image kindest/node:v1.37.0
kind create cluster --name starbuck --image kindest/node:v1.37.0
```

Switch between clusters using:

```bash
kubectl config use-context kind-apollo
kubectl config use-context kind-starbuck
```

> **Important:** Complete the remaining steps for the `apollo` cluster and then repeat them for `starbuck`. The commands are shown for `apollo`; the differing values for `starbuck` are given where they matter.

### Configuration

All platform Helmfiles live in `platform/helmfile.d` and are applied one by one with `-f` (the steps depend on information, such as the load balancer IP, that is only known after an earlier step has completed). Run all commands from the root of this repository.

```bash
export RELEASE_NAME=cs
export CLUSTER=apollo          # starbuck for the second cluster
kubectl config use-context kind-${CLUSTER}
```

Helmfile adds the required Helm repositories on its own.

### MetalLB

MetalLB hands out external IPs to `LoadBalancer` services on the kind Docker network. Each cluster gets its own address pool, so that the two clusters can reach each other:

| Cluster | `METALLB_ADDRESS_POOL` |
|---|---|
| `apollo` | `172.18.1.128/25` |
| `starbuck` | `172.18.2.128/25` |

> **Compatibility note:** The original guide used `172.18.1.255/25` and `172.18.2.255/25`, which are not the network addresses of those `/25` networks. This repository uses the canonical CIDRs `172.18.1.128/25` and `172.18.2.128/25` (the same address range). Whether MetalLB v0.16.1 would accept the original notation was not tested. The pools must be inside the Docker `kind` network (`docker network inspect kind`, usually `172.18.0.0/16`); adjust them if your kind network differs.

```bash
export METALLB_ADDRESS_POOL=172.18.1.128/25   # 172.18.2.128/25 for starbuck
helmfile -f platform/helmfile.d/0010.metallb.yaml.gotmpl sync
```

This

* labels the `metallb-system` namespace with the `privileged` pod security level (required by the MetalLB speaker),
* installs MetalLB v0.16.1 in layer 2 mode only (the FRR/BGP backend `frr-k8s`, enabled by default since v0.15, is switched off, as it is not needed), and
* creates the `default` `IPAddressPool` and the `empty` `L2Advertisement` (chart `platform/charts/metallb-config`).

### Istio

The Istio Operator is not part of recent Istio releases, so Istio is installed with the `base`, `istiod` and `gateway` Helm charts (chart repository `https://blob.istio.io/istio-release/charts`; the former `istio-release.storage.googleapis.com` repository is stale). The settings of the former `IstioOperator` resource are expressed as Helm values in `platform/helmfile.d/0020.istio.yaml.gotmpl`, with the same intent:

* ingress gateway ports `15021`, `80→8080`, `443→8443`, `1443→9443` (inter-VCP mTLS), `2379→9379` (etcd mTLS), `15443` and the Ephemeral MPC ports `30000-30004`;
* egress gateway ports `80-84→8080-8084` (port `80+i` is the route to partner VC `i`; at most five partners) and `2379→8379` (etcd);
* sidecar injection is `disabled` by default and enabled by `alwaysInjectSelector` for pods labeled `sidecar/inject`, Amphora and Castor, the Klyshko operator (`control-plane: controller-manager`) and `${RELEASE_NAME}-ephemeral-discovery`;
* DNS capture/auto-allocation, access log to stdout, trace sampling 100 %, no autoscaling, small resource requests.

```bash
helmfile -f platform/helmfile.d/0020.istio.yaml.gotmpl sync
```

The gateways are created from the release names `istio-ingressgateway` and `istio-egressgateway` in `istio-system`, so the `istio: ingressgateway` / `istio: egressgateway` labels and the service names are the same as in the original setup. The egress gateway service is of type `ClusterIP`, as before.

Enable automatic sidecar injection for the `default` namespace (the Carbyne Stack services are deployed there):

```bash
kubectl label namespace default istio-injection=enabled
```

Wait until MetalLB has assigned an external IP to the ingress gateway and export it:

```bash
kubectl get services --namespace istio-system istio-ingressgateway -w

export EXTERNAL_IP=$(kubectl get services --namespace istio-system \
  istio-ingressgateway \
  --output jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $EXTERNAL_IP    # 172.18.1.128 for apollo, 172.18.2.128 for starbuck
```

### Knative

Knative Serving is installed with the Knative Operator Helm chart (`v1.23.0`) and a `KnativeServing` resource (chart `platform/charts/knative-serving`) that

* deploys the Knative Serving and net-istio manifests,
* uses `${EXTERNAL_IP}.sslip.io` as the domain,
* raises `max-revision-timeout-seconds` from `600` to `36000` seconds (10 hours; Ephemeral computations run as Knative activations and are subject to this timeout), and
* exposes Knative through the Istio ingress gateway on HTTPS port 443, TLS secret `${TLS_SECRET_NAME}`.

**TLS secret.** Istio 1.31 rejects an HTTPS gateway server that has no TLS settings, so the name of the TLS secret has to be part of the Knative gateway from the start (the original guide patched it in afterwards). Choose the name now: `apollo-tls-secret-generic` for `apollo`, `starbuck-tls-secret-generic` for `starbuck`. The secret itself is created in [stack-deployment.md](stack-deployment.md#tls); Istio picks it up when it appears.

**Patched Knative Serving.** Carbyne Stack requires Knative Serving with a patch that allows multiple ports across the containers of a pod (Ephemeral exposes the MPC engine ports next to the user container port). The patch (`patches/knative-serving-v1.23.0-multiport.patch`) applies cleanly to the Knative `v1.23.0` source and the unit tests of the changed packages pass, but **no patched build of Knative 1.23 has been published** (upstream Carbyne Stack only provides `v1.8.2-multiport-patch` and `v0.19.0-multiport-patch`). You have to build and host it yourself:

```bash
KO_DOCKER_REPO=ghcr.io/<owner>/knative-serving scripts/build-serving-patch.sh ./serving-build
# publish serving-build/serving-crds.yaml and serving-build/serving-core.yaml, e.g. as release assets, then
export SERVING_MANIFEST_BASE_URL=https://github.com/<owner>/serving/releases/download/v1.23.0-multiport-patch
```

The images in `KO_DOCKER_REPO` must be pullable from the clusters. The build script has **not** been run end to end; the live validation used the unpatched upstream manifests (`SERVING_MANIFEST_BASE_URL=https://github.com/knative/serving/releases/download/knative-v1.23.0`), which is sufficient to validate the platform but not for deploying Ephemeral.

```bash
export TLS_SECRET_NAME=apollo-tls-secret-generic   # starbuck-tls-secret-generic for starbuck
helmfile -f platform/helmfile.d/0030.knative.yaml.gotmpl sync
kubectl wait knativeserving/knative-serving -n knative-serving --for=condition=Ready --timeout=600s
```

`net-certmanager` (installed by the original guide) is not installed: no release newer than v1.14.0 exists, and nothing in the Carbyne Stack Helmfiles uses cert-manager (TLS secrets are created by hand).

### Postgres Operator

Install the [Zalando Postgres Operator](https://github.com/zalando/postgres-operator) v2.0.3 in the `default` namespace (the Carbyne Stack Helmfiles create their `postgresql` resources there):

```bash
helmfile -f platform/helmfile.d/0040.postgres-operator.yaml.gotmpl sync
```

The operator's default Spilo image is `ghcr.io/zalando/spilo-18:4.1-p2`; it still ships PostgreSQL 15, which is what the Carbyne Stack `postgres-dbms` chart requests (`postgresVersion` value, default `"15"`).

## Verification

```bash
kubectl get nodes                                       # one node, v1.37.0
kubectl get pods -n metallb-system                      # controller + speaker Running
kubectl get ipaddresspool,l2advertisement -n metallb-system
kubectl get pods -n istio-system                        # istiod, ingress and egress gateway Running
kubectl get svc -n istio-system istio-ingressgateway    # EXTERNAL-IP from the pool
kubectl get knativeserving -n knative-serving           # READY True
kubectl get pods -n knative-serving                     # activator, autoscaler, controller, webhook, net-istio-*
kubectl get gateways.networking.istio.io -n knative-serving   # knative-ingress-gateway, knative-local-gateway
kubectl get pods -n default                             # postgres-operator Running
kubectl get crd postgresqls.acid.zalan.do
kubectl get namespace default --show-labels | grep istio-injection=enabled
```

The platform is ready for the Carbyne Stack deployment when all of these succeed.

### Verification status

What was actually executed (single kind cluster `cstest`, `kindest/node:v1.37.0`, Helm v3.22.1, Helmfile v1.8.2, MetalLB pool `172.18.5.128/25`):

| Step | Result |
|---|---|
| `0010.metallb` (with `frrk8s` disabled) | controller + speaker Running; pool and L2 advertisement created |
| `0020.istio` | istiod, ingress, egress gateway Running; ingress got `172.18.5.128` from MetalLB |
| `0030.knative` with **unpatched** upstream Knative 1.23.0 manifests | `KnativeServing` `Ready=True`; activator, autoscaler, controller, webhook, net-istio-controller/webhook Running; Gateway created with TLS settings |
| `0040.postgres-operator` | operator v2.0.3 Running; CRDs present |
| `deployments` `0010.dbms` (stack, player 0) | `postgresql` cluster `Running` with PostgreSQL 15.17 (Spilo 18), roles/secrets `cs`, `hydra`, `kratos`, `postgres`, `standby`, databases `amphora`, `castor`, `hydra`, `kratos` created; password login as `hydra` through the service name works; `password_encryption` is `scram-sha-256` |
| Static validation (`scripts/validate.sh`) | all Helmfiles of platform and stack (both players) render; kubeconform (k8s 1.37.0, strict) reports no invalid resource except a known upstream chart defect (see CHANGES.md); pluto finds no deprecated APIs |

**Not executed:** the second cluster and cross-cluster connectivity, the patched Knative Serving build, a Knative `Service` (including a multi-port one) end to end, TLS through the Knative gateway, and the Carbyne Stack services (MinIO, etcd, Redis, Thymus, Castor, Amphora, Ephemeral, Klyshko).

## Clean Up

If you no longer need the clusters, tear them down:

```bash
kind delete cluster --name apollo
kind delete cluster --name starbuck
```

## Troubleshooting

### OpenVPN

If you use OpenVPN and kind fails to create its Docker network (`could not find an available, non-overlapping IPv4 address pool`), free the address range used by kind or adjust the Docker `default-address-pools`; see the [kind known issues](https://kind.sigs.k8s.io/docs/user/known-issues/).

### kind

If one of your kind clusters does not start all pods, there may be an issue with limited inotify resources on Linux. Check the logs of the faulty pods, for example `kubectl logs -n kube-system <pod-name>`. If the output contains `too many open files`, follow the [kind troubleshooting advice](https://kind.sigs.k8s.io/docs/user/known-issues/#pod-errors).

### Knative `KnativeServing` is not `Ready`

Inspect the conditions: `kubectl get knativeserving -n knative-serving knative-serving -o yaml`. A message from the `validation.istio.io` admission webhook points to an invalid Istio `Gateway` (Istio 1.31 rejects `targetPort` on gateway server ports and HTTPS servers without TLS settings; both are handled by the chart).
