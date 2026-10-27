#!/bin/bash
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#
# Removes what deploy-gateway.sh created: the gateway container, the ingress rules and Traefik.
#
# Usage: remove-gateway.sh [--context <kube-context>]
set -e

EXAMPLE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTEXT="cluster-dev"
GATEWAY="gateway"

while [[ $# -gt 0 ]]; do
  case $1 in
    --context) CONTEXT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

run() {
  echo "==> RUN: $*"
  "$@"
}

run container stop "$GATEWAY" 2>/dev/null || true
run container delete "$GATEWAY" 2>/dev/null || true
run rm -rf "$EXAMPLE_ROOT/.gateway/$GATEWAY"

run kubectl --context "$CONTEXT" delete ingress notepad notepad-api --ignore-not-found
run helm uninstall traefik --kube-context "$CONTEXT" --namespace traefik 2>/dev/null || true
