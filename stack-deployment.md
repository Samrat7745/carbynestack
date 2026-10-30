# Stack Deployment Guide

This guide describes how to set up a Carbyne Stack Virtual Cloud (VC) consisting of two Virtual Cloud Providers (VCPs) on the platform prepared with [platform-setup.md](platform-setup.md). The Helmfiles in `deployments/helmfile.d` are derived from the Carbyne Stack SDK `0.8.1` Helmfiles; the deployed Carbyne Stack component versions are unchanged.

> **Validation status.** The Helmfiles of this guide render for both players and pass static validation (`scripts/validate.sh`: kubeconform on Kubernetes 1.37.0, pluto). Only the database release (`0010.dbms`) has been deployed to a cluster, see [platform-setup.md](platform-setup.md#verification-status). **A complete Virtual Cloud deployment (all releases, both clusters) has not been executed or verified.** The TLS, Knative-gateway and Helmfile steps below follow the original guide and have not been exercised on the upgraded platform.

## Prerequisites

> **Warning:** The versions below are the ones used to develop this guide. Other versions may work, but are untested.

* Helmfile v1.8.2, Helm v3.22.1, Helm Diff Plugin v3.15.15 (only for `helmfile diff`/`apply`)
* `kubectl` v1.37.x, `openssl`

The guide assumes two clusters `apollo` and `starbuck` set up as described in [platform-setup.md](platform-setup.md) with

* Kubernetes v1.37.0
* Istio v1.31.3 (with the Carbyne Stack gateway ports and `istio-injection=enabled` on the `default` namespace)
* MetalLB v0.16.1
* Knative Serving v1.23.0 — **the Carbyne Stack multi-port patched build** (required for Ephemeral; see the Knative section of the platform guide, there is no published build for 1.23)
* Zalando Postgres Operator v2.0.3

> **Tip:** On a slow internet connection, use `kind load docker-image <image> --name <cluster-name>` to load images from your local Docker registry into the kind clusters. This lets you download images only once and reuse them across VCP deployments.

## Virtual Cloud Deployment

1. Enter the deployments directory of this repository:

   ```bash
   cd deployments
   ```

   Chart versions and images of the Carbyne Stack components are the ones of SDK `0.8.1` (Castor 0.4.0, Amphora 0.3.1, Ephemeral 0.3.0, Klyshko 0.4.0, Thymus 0.6.2, etcd 8.3.1, Redis 17.14.6, MinIO 3.6.6).

2. Set common configuration before deploying the Virtual Cloud Providers.

   > **Attention:** Replace `172.18.1.128` and `172.18.2.128` with the load balancer IPs assigned to the Istio ingress gateway by MetalLB (see the platform guide, `echo $EXTERNAL_IP`).

   ```bash
   export APOLLO_IP="172.18.1.128"
   export APOLLO_FQDN="${APOLLO_IP}.sslip.io"
   export STARBUCK_IP="172.18.2.128"
   export STARBUCK_FQDN="${STARBUCK_IP}.sslip.io"
   export PARTNER_COUNT=2
   export PARTNER_FQDN_0=$APOLLO_FQDN
   export PARTNER_FQDN_1=$STARBUCK_FQDN
   export ETCD_MASTER_URL=$APOLLO_FQDN
   export ETCD_MASTER_IP=$APOLLO_IP
   export RELEASE_NAME=cs
   export NO_SSL_VALIDATION=true
   export TLS_ENABLED=true # Enabled by default, set to false to disable
   export PROTOCOL=https
   ```

   `RELEASE_NAME` must be the value used in the platform setup (the Istio sidecar injection selector refers to it). `PLAYER_ID` (`0` apollo, `1` starbuck) and `TLS_SECRET_NAME` are set per VCP in the launch steps below. All further variables are optional (image versions, MAC key shares, scheduler thresholds, ...); see the `env` calls in `deployments/helmfile.d`.

3. Configure the Correlated Randomness Generator (CRG) used by Klyshko.

   **Insecure configuration (default)**

   > **Danger:** DO NOT USE THIS IN A PRODUCTION SETTING.
   >
   > By default, correlated randomness is generated using a cheap but insecure fake offline phase implementation. This CRG is recommended for development and demo purposes only.

   **Secure configuration**

   > **Warning:** In this configuration, CR generation consumes substantial CPU and bandwidth. The offline-phase Docker container is platform-dependent, so execution may fail on some platforms.

   Carbyne Stack includes an experimental correlated randomness generator based on the MP-SPDZ CowGear offline-phase implementation. Enable it before proceeding:

   ```bash
   export KLYSHKO_GENERATOR_IMAGE_REPOSITORY=carbynestack/klyshko-mp-spdz-cowgear
   export KLYSHKO_GENERATOR_IMAGE_TAG=0.2.0
   ```

4. <a id="tls"></a>Configure TLS for secure communication to and between the VCPs.

   The secrets must exist in the namespace of the proxy and the components using the certificates. They are created in `istio-system` and then copied to `knative-serving` and `default`. The secret names must match `TLS_SECRET_NAME` used when installing Knative in the platform setup.

   ```bash
   # Create X.509 certificates
   mkdir -p certs
   openssl req -x509 -newkey rsa:4096 -keyout certs/apollo_key.pem -out certs/apollo_cert.pem -days 365 -nodes -subj "/CN=${APOLLO_FQDN}" -addext "subjectAltName=DNS:${APOLLO_FQDN},IP:${APOLLO_IP}"
   openssl req -x509 -newkey rsa:4096 -keyout certs/starbuck_key.pem -out certs/starbuck_cert.pem -days 365 -nodes -subj "/CN=${STARBUCK_FQDN}" -addext "subjectAltName=DNS:${STARBUCK_FQDN},IP:${STARBUCK_IP}"

   # Create Kubernetes secrets using the generated keys and certificates
   kubectl config use-context kind-apollo
   kubectl create secret generic apollo-tls-secret-generic -n istio-system --from-file=tls.key=certs/apollo_key.pem --from-file=tls.crt=certs/apollo_cert.pem --from-file=cacert=certs/starbuck_cert.pem
   kubectl get secret apollo-tls-secret-generic -n istio-system -o yaml | sed 's/namespace: istio-system/namespace: knative-serving/' | kubectl apply -n knative-serving -f -
   kubectl get secret apollo-tls-secret-generic -n istio-system -o yaml | sed 's/namespace: istio-system/namespace: default/' | kubectl apply -n default -f -

   kubectl config use-context kind-starbuck
   kubectl create secret generic starbuck-tls-secret-generic -n istio-system --from-file=tls.key=certs/starbuck_key.pem --from-file=tls.crt=certs/starbuck_cert.pem --from-file=cacert=certs/apollo_cert.pem
   kubectl get secret starbuck-tls-secret-generic -n istio-system -o yaml | sed 's/namespace: istio-system/namespace: knative-serving/' | kubectl apply -n knative-serving -f -
   kubectl get secret starbuck-tls-secret-generic -n istio-system -o yaml | sed 's/namespace: istio-system/namespace: default/' | kubectl apply -n default -f -
   ```

   The `certs/` directory contains private keys and is git-ignored.

5. Verify that the Knative gateway uses the certificates.

   The original guide patched the TLS settings into the Knative ingress gateway at this point. Istio 1.31 refuses to create an HTTPS gateway server without TLS settings, so the Knative platform Helmfile already creates `knative-ingress-gateway` with `tls.mode: SIMPLE` and `credentialName: ${TLS_SECRET_NAME}`. No patch is needed; check it instead:

   ```bash
   kubectl config use-context kind-apollo
   kubectl get gateway.networking.istio.io knative-ingress-gateway -n knative-serving -o jsonpath='{.spec.servers[0].tls}'
   # {"credentialName":"apollo-tls-secret-generic","mode":"SIMPLE"}

   kubectl config use-context kind-starbuck
   kubectl get gateway.networking.istio.io knative-ingress-gateway -n knative-serving -o jsonpath='{.spec.servers[0].tls}'
   # {"credentialName":"starbuck-tls-secret-generic","mode":"SIMPLE"}
   ```

   If the secret name differs from the one used when installing Knative, re-run `platform/helmfile.d/0030.knative.yaml.gotmpl` with the right `TLS_SECRET_NAME`.

6. Launch the `starbuck` VCP:

   ```bash
   export PLAYER_ID=1
   export TLS_SECRET_NAME=starbuck-tls-secret-generic
   kubectl config use-context kind-starbuck
   helmfile sync --set thymus.users.enabled=true
   ```

   `--set thymus.users.enabled=true` makes the Thymus release create demo users (`create-user-*` jobs, credentials secrets, mailslurper). etcd only runs on the master (`apollo`), so the etcd Helmfile has no releases on player 1; with `helmfile template` this made Helmfile exit with code 3 during static validation. Whether `helmfile sync` behaves the same was not tested.

7. Launch the `apollo` VCP:

   ```bash
   export PLAYER_ID=0
   export TLS_SECRET_NAME=apollo-tls-secret-generic
   kubectl config use-context kind-apollo
   helmfile sync --set thymus.users.enabled=true
   ```

8. Wait until all pods in both clusters are in the `Ready` state.

You now should have a fully functional Carbyne Stack Virtual Cloud.

## Verification

```bash
for var in apollo starbuck
do
  kubectl config use-context kind-$var
  helmfile status            # all releases deployed
  kubectl get pods           # all pods Ready (Jobs Completed)
  kubectl get postgresql     # STATUS Running
done
```

Beyond pod readiness, check that the VCPs can talk to each other (Istio egress/ingress gateway routing, etcd on `apollo`, Klyshko → Castor tuple generation) with the checks of the Carbyne Stack SDK. These end-to-end checks have not been run against this repository.

## Teardown the Virtual Cloud

Tear down the Virtual Cloud by removing the Virtual Cloud Providers:

```bash
for var in apollo starbuck
do
  kubectl config use-context kind-$var
  helmfile destroy
done
```

`helmfile destroy` leaves the TLS secrets created in step 4 in place; delete them with `kubectl delete secret <name> -n istio-system` (and in `knative-serving`/`default`) and remove `certs/` if you do not need them anymore. The platform (MetalLB, Istio, Knative, Postgres operator) is removed by deleting the kind clusters (see the platform guide).
