# Carbyne Stack Deployment (modernized)

Helmfile-based deployment of a two-party Carbyne Stack Virtual Cloud (SDK `0.8.1` component versions) on a current platform: Kubernetes 1.37, Istio 1.31, MetalLB 0.16, Knative 1.23 and the Zalando Postgres Operator 2.0.

| | |
|---|---|
| [platform-setup.md](platform-setup.md) | Prerequisites, kind clusters, MetalLB, Istio, Knative, Postgres operator, verification |
| [stack-deployment.md](stack-deployment.md) | Environment, TLS, Virtual Cloud Providers, verification, teardown |
| [test-deployment.md](test-deployment.md) | Ordered, copy-paste walkthrough for testing the deployment with the Docker Hub images |
| [CHANGES.md](CHANGES.md) | Major changes, compatibility issues, operator decision, what was *not* verified |

```
platform/helmfile.d/     MetalLB, Istio, Knative, Postgres operator (applied one by one with -f)
platform/charts/         metallb-config, knative-serving (KnativeServing resource)
deployments/helmfile.d/  Carbyne Stack stack (helmfile sync from deployments/)
deployments/charts/      postgres-dbms, istio, klyshko
patches/                 Knative Serving multi-port patch (v1.23.0)
scripts/validate.sh      offline render + kubeconform + pluto check
scripts/build-serving-patch.sh   builds the patched Knative Serving manifests
scripts/serve-serving-manifests.sh   serves serving/ to the kind clusters over HTTP
serving/                 patched Knative Serving 1.23.0 manifests (digest-pinned images)
```

**Status:** the platform Helmfiles and the database release were deployed on a single kind cluster (see the verification table in the platform guide); a complete Virtual Cloud deployment was not executed. The patched Knative Serving 1.23 manifests are in `serving/v1.23.0-multiport/` (images on Docker Hub); they have not been installed on a cluster yet.

License: Apache-2.0 (see [LICENSE](LICENSE), [NOTICE.md](NOTICE.md)).
