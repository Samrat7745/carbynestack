#!/usr/bin/env bash
#
# Copyright (c) 2021-2026 - for information on the respective copyright owner
# see the NOTICE file and/or the repository https://github.com/carbynestack/carbynestack.
#
# SPDX-License-Identifier: Apache-2.0
#
# Static validation (no cluster needed): renders all Helmfiles of the platform and of the stack for both players,
# validates the manifests against the Kubernetes API schemas and checks for deprecated/removed APIs.
# This does NOT prove that a deployment works; see platform-setup.md / stack-deployment.md for the live steps.
#
# Requires: helmfile, helm, kubeconform, pluto. Optional: HELM_BIN, K8S_VERSION (default 1.37.0).
set -euo pipefail

cd "$(dirname "$0")/.."
K8S_VERSION="${K8S_VERSION:-1.37.0}"
HELM_BIN="${HELM_BIN:-helm}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

hf() { helmfile --helm-binary "$HELM_BIN" "$@"; }

# Dummy values for the variables the Helmfiles require
export RELEASE_NAME=cs PARTNER_COUNT=2 PARTNER_FQDN_0=172.18.1.128.sslip.io PARTNER_FQDN_1=172.18.2.128.sslip.io
export ETCD_MASTER_URL=172.18.1.128.sslip.io ETCD_MASTER_IP=172.18.1.128 NO_SSL_VALIDATION=true TLS_ENABLED=true
export PROTOCOL=https EXTERNAL_IP=172.18.1.128 TLS_SECRET_NAME=apollo-tls-secret-generic
export METALLB_ADDRESS_POOL=172.18.1.128/25 SERVING_MANIFEST_BASE_URL=https://example.invalid/serving

echo "== Rendering platform"
(cd platform/helmfile.d && for f in *.gotmpl; do hf -f "$f" template > "$OUT/platform-$f.yaml"; done)

echo "== Rendering stack (player 0 and 1)"
for player in 0 1; do
  (cd deployments && PLAYER_ID=$player hf template --set thymus.users.enabled=true > "$OUT/stack-$player.yaml" || {
    # Player 1 has no etcd release; helmfile reports exit code 3 for the empty file only
    [ "$player" = 1 ] && [ "$?" = 3 ] || exit 1; })
done

echo "== kubeconform (Kubernetes $K8S_VERSION, strict)"
KC="$OUT/kubeconform.log"
kubeconform -strict -ignore-missing-schemas -kubernetes-version "$K8S_VERSION" -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -skip OperatorConfiguration \
  "$OUT"/*.yaml | tee "$KC" || true
# Known upstream issue: the published Ephemeral 0.3.0 chart renders serviceAccountName twice (same value) in the
# network-controller Deployment. It is harmless for the API server; anything else is a failure.
if grep -E 'failed validation|Errors?: [1-9]' "$KC" | grep -v -e 'cs-ephemeral-network-controller failed validation' -e 'Summary:' >/dev/null; then
  echo "kubeconform reported unexpected errors" >&2; exit 1
fi
if grep -E 'Invalid: [1-9]' "$KC" >/dev/null; then echo "kubeconform reported invalid resources" >&2; exit 1; fi

echo "== pluto (deprecated / removed APIs)"
pluto detect-files -d "$OUT" --target-versions "k8s=v${K8S_VERSION}"
echo "OK"
