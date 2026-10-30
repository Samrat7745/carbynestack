#!/usr/bin/env bash
#
# Copyright (c) 2021-2026 - for information on the respective copyright owner
# see the NOTICE file and/or the repository https://github.com/carbynestack/carbynestack.
#
# SPDX-License-Identifier: Apache-2.0
#
# Serves serving/v1.23.0-multiport (patched Knative Serving manifests) over HTTP on the gateway of the Docker `kind`
# network, so that the Knative Operator inside the kind clusters can download them without publishing them anywhere.
# Keep it running while installing Knative (platform/helmfile.d/0030.knative.yaml.gotmpl) and use
#   export SERVING_MANIFEST_BASE_URL=http://<gateway>:8000
# The images referenced by the manifests are public on Docker Hub (deadstrider/*) and pinned by digest.
set -euo pipefail
cd "$(dirname "$0")/../serving/v1.23.0-multiport"
GATEWAY="$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
echo "SERVING_MANIFEST_BASE_URL=http://${GATEWAY}:8000"
exec python3 -m http.server 8000 --bind "$GATEWAY"
