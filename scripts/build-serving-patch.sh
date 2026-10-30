#!/usr/bin/env bash
#
# Copyright (c) 2021-2026 - for information on the respective copyright owner
# see the NOTICE file and/or the repository https://github.com/carbynestack/carbynestack.
#
# SPDX-License-Identifier: Apache-2.0
#
# Builds the Carbyne Stack multi-port patched Knative Serving (serving-crds.yaml, serving-core.yaml) for a Knative
# release. There is no published patched build for Knative 1.23 (the last ones are v1.8.2-multiport-patch and
# v0.19.0-multiport-patch of github.com/carbynestack/serving), so it has to be built and hosted by you.
#
# Usage: KO_DOCKER_REPO=ghcr.io/<owner>/knative-serving scripts/build-serving-patch.sh [output-dir]
#   KNATIVE_VERSION  Knative release to build (default 1.23.0)
# Requires: git, go, ko (logged in to KO_DOCKER_REPO's registry, which must be pullable from the clusters).
# The result in <output-dir> (default ./serving-build) is to be published (e.g. as GitHub release assets); its URL is
# SERVING_MANIFEST_BASE_URL for platform/helmfile.d/0030.knative.yaml.gotmpl.
set -euo pipefail

: "${KO_DOCKER_REPO:?KO_DOCKER_REPO must be set, e.g. ghcr.io/<owner>/knative-serving}"
KNATIVE_VERSION="${KNATIVE_VERSION:-1.23.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/patches/knative-serving-v${KNATIVE_VERSION}-multiport.patch"
OUT="$(realpath -m "${1:-./serving-build}")"
[ -f "$PATCH" ] || { echo "no patch for Knative $KNATIVE_VERSION: $PATCH" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone --depth 1 --branch "knative-v${KNATIVE_VERSION}" https://github.com/knative/serving.git "$WORK/serving"
cd "$WORK/serving"
git apply --check "$PATCH"
git apply "$PATCH"

# Unit tests of the packages the patch touches
go test ./pkg/apis/serving/... ./pkg/reconciler/revision/resources/...

# Upstream's own generator writes serving-core.yaml, serving-crds.yaml (and the post-install/HPA files) with the
# images built by ko and pushed to KO_DOCKER_REPO
mkdir -p "$OUT"
YAML_OUTPUT_DIR="$OUT" KO_FLAGS="--platform=linux/amd64" TAG="v${KNATIVE_VERSION}" \
  ./hack/generate-yamls.sh "$PWD" "$WORK/yaml-list" "$WORK/yaml-env"
echo "Built $OUT/serving-core.yaml and $OUT/serving-crds.yaml; publish them and set SERVING_MANIFEST_BASE_URL."
