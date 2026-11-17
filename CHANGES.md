# Summary of Changes and Compatibility Considerations

This repository modernizes the Carbyne Stack deployment blueprint (SDK `0.8.1`, Helmfiles in `deployments/helmfile.d` and the Platform Setup / Stack Deployment guides) for newer platform versions. The Terraform/CDKTF code of the original repository was not used. The deployed Carbyne Stack component versions are unchanged.

For what was actually executed versus only statically validated see [Verification status](platform-setup.md#verification-status). In short: platform Helmfiles (MetalLB, Istio, Knative with unpatched upstream manifests, Zalando operator) and the stack database release were deployed on one kind cluster; nothing else of the stack was; the patched Knative build was not built.

## Version changes

| Component | From | To |
|---|---|---|
| Kubernetes (`kindest/node`) | v1.26.6 | v1.37.0 |
| Istio | v1.17.0 | v1.31.3 |
| MetalLB | v0.13.9 | v0.16.1 |
| Knative Serving / Operator / net-istio | v1.8.2 | v1.23.0 |
| Zalando Postgres Operator | v1.9.0 | v2.0.3 |
| Helm / Helmfile / helm-diff / kind / kubectl | 3.11.1 / 0.142.0 / 3.1.3 / 0.17.0 / 1.26.1 | 3.22.1 / 1.8.2 / 3.15.15 / 0.33.0 / 1.37.x |

## Major implementation changes

* **Platform as Helmfiles** (`platform/`): MetalLB, Istio, Knative and the Postgres operator are installed with Helmfiles and small local charts (`platform/charts/metallb-config`, `platform/charts/knative-serving`) instead of manually generated and applied YAML. The per-step order and the cluster-specific values (`METALLB_ADDRESS_POOL`, `EXTERNAL_IP`, `TLS_SECRET_NAME`) are unchanged in spirit.
* **Istio without the operator**: the Istio Operator and `IstioOperator` resource are gone from the Istio distribution. The same configuration (gateway ports, `alwaysInjectSelector`, DNS capture, disabled auto injection, trace sampling, resources) is applied through the `base`, `istiod` and `gateway` Helm charts. Chart repository: `https://blob.istio.io/istio-release/charts`.
* **Knative via the Knative Operator Helm chart** and a `KnativeServing` resource with `spec.manifests`, `ingress.istio`, `config` as before; `net-istio` now comes from `knative-extensions/net-istio` (the old `knative/net-istio` URL is gone).
* **Helmfile v1**: templated Helmfiles need the `.gotmpl` extension, so all `deployments/helmfile.d/*.yaml` were renamed to `*.yaml.gotmpl` (content unchanged apart from the items below).
* **Istio API version**: the stack's Istio chart (`deployments/charts/istio`) uses `networking.istio.io/v1` instead of `v1beta1`; the local charts are Helm `apiVersion: v2`.
* **Postgres version is explicit**: `deployments/charts/postgres-dbms` has a `postgresVersion` value (default `"15"`, unchanged behaviour).
* **Bug fix carried along**: in `0450.klyshko-config.yaml.gotmpl` the MAC key share `2` of player 1 read `0_MAC_KEY_SHARE_2` (copy/paste error in the original); it now reads `1_MAC_KEY_SHARE_2`. Only deployments overriding `1_MAC_KEY_SHARE_2` are affected differently.

## Compatibility issues and decisions

1. **Patched Knative Serving for 1.23 had to be built.** Carbyne Stack needs Knative Serving patched to allow multiple ports across containers; published builds exist only for v1.8.2 and v0.19.0. `patches/knative-serving-v1.23.0-multiport.patch` (rebased onto `knative-v1.23.0`, unit tests of the changed packages pass) was built with `scripts/build-serving-patch.sh`; the images are on Docker Hub (`deadstrider/*`, digest-pinned) and the generated manifests are in `serving/v1.23.0-multiport/`. They are served to the clusters with `scripts/serve-serving-manifests.sh`. The build and image push succeeded and the HTTP serving path was checked from the `kind` network, but **the patched build has not been installed on a cluster**. `SERVING_MANIFEST_BASE_URL` still has no default.
2. **Istio 1.31 rejects HTTPS gateway servers without TLS settings and `targetPort` on gateway ports** (found by deploying; the validating webhook of `istiod` refuses the Knative gateway). The `target_port: 443` of the original `KnativeServing` was dropped and the TLS credential name is set at creation, so the manual `kubectl patch gateway` step of the original guide became a verification step. Consequence: `TLS_SECRET_NAME` is required when installing Knative.
3. **`net-certmanager` dropped**: the last release is v1.14.0; Knative 1.23 has none and nothing in the Helmfiles uses cert-manager.
4. **Istio chart repository moved** from `istio-release.storage.googleapis.com/charts` (stale, ends at 1.31.0-rc) to `blob.istio.io/istio-release/charts`.
5. **MetalLB 0.16 enables FRR (BGP) by default**; switched off, since layer 2 mode is used (saves a five-container daemon set per cluster). Pool CIDRs were normalized to `172.18.1.128/25` / `172.18.2.128/25`.
6. **PostgreSQL 15 on Spilo 18**: operator v2.0.3 defaults to `spilo-18`, which still contains PostgreSQL 15; verified live (15.17). Password hashing defaults to `scram-sha-256` in v2; the connecting services were not tested against it (Thymus/Ory, Castor, Amphora connect with the same secrets as before). Operator v2 deprecates Kubernetes Endpoints in favor of ConfigMaps (default); none of the removed manifest fields are used by `postgres-dbms`.
7. **Published Ephemeral 0.3.0 chart bug**: the `network-controller` Deployment contains the key `serviceAccountName` twice (same value). Harmless for the API server, but strict YAML parsing (kubeconform) flags it; `scripts/validate.sh` tolerates exactly this case.
8. **Stackable OPA operator 24.7.0 / OPA 0.66.0 (Thymus)**: still resolvable and pullable, but they are old; their behavior on Kubernetes 1.37 was not tested.
9. **Component images/charts of Carbyne Stack are unchanged** (SDK 0.8.1 versions, Bitnami etcd 8.3.1 with the `bitnamilegacy` image, Bitnami Redis 17.14.6, MinIO chart 3.6.6). Their compatibility with Kubernetes 1.37 was verified statically only (kubeconform, pluto), not at runtime.

## PostgreSQL operator: Zalando 2.0.3 vs CloudNativePG

**Decision: Zalando Postgres Operator v2.0.3.**

* The Carbyne Stack Helmfiles and the upstream component charts (Castor, Amphora, Thymus/Ory) are written against the Zalando resource model: a `postgresqls.acid.zalan.do` resource (`postgres-dbms` chart), the service `cs-<release>-postgres-dbms` and the credential secrets `<user>.cs-<release>-postgres-dbms.credentials.postgresql.acid.zalan.do`. v2.0.3 keeps all of these unchanged (verified live).
* CloudNativePG would replace the CRD, the service names (`-rw`/`-ro`) and the secret layout (`<cluster>-app` with different keys), which means changing the published component charts or Helmfile glue in castor, amphora and thymus — an architectural change the task excludes.
* CloudNativePG v1.27.1 is also not the newest minor line, so it would not even reduce version drift.
* Risks accepted: Spilo/PostgreSQL 15 image compatibility (verified live), scram-sha-256 default (see item 6).

## Container images

The Helmfile defaults point to Go builds published on Docker Hub (`deadstrider/{castor-service,amphora-service,ephemeral-discovery,ephemeral-network-controller,klyshko-operator,thymus-policy-catalogue}:0.1.2-go`); every image can be overridden per component through `<NAME>_IMAGE_{REGISTRY,REPOSITORY,TAG}` (falling back to the upstream Java images is possible). The Ephemeral MPC engine keeps its upstream image because the Go build lacks the MP-SPDZ runtime. Compatibility of the Go images with the *published* SDK 0.8.1 charts was not tested on a cluster. See [test-deployment.md](test-deployment.md).

## Not verified

Second cluster, cross-cluster routing, the patched Knative build, Knative `Service` creation, TLS through the gateway, and all Carbyne Stack services except the database. Treat the documentation of those steps as untested.
