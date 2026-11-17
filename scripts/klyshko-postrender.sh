#!/usr/bin/env bash
#
# Helm post-renderer for the Klyshko release: the published chart hardcodes
# gcr.io/kubebuilder/kube-rbac-proxy:v0.8.0, which no longer exists (kubebuilder retired its gcr.io images).
# Replaces it with ${KUBE_RBAC_PROXY_IMAGE} (default quay.io/brancz/kube-rbac-proxy:v0.23.1).
set -euo pipefail
exec sed "s#gcr.io/kubebuilder/kube-rbac-proxy:v0.8.0#${KUBE_RBAC_PROXY_IMAGE:-quay.io/brancz/kube-rbac-proxy:v0.23.1}#g"
