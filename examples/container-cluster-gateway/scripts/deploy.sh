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

set -e

# The cluster name is also the kubectl context that "container cluster create" adds to ~/.kube/config.
CLUSTER="${1:-cluster-dev}"
EXAMPLE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

run() {
  echo "==> RUN: $*"
  "$@"
}

# Loads each image into every node of the cluster. "container build" names the images
# docker.io/library/demo-*:latest, which is the name that the manifests in deployment/ use.
run container cluster load-image --name "$CLUSTER" demo-api:latest
run container cluster load-image --name "$CLUSTER" demo-web:latest

run kubectl --context "$CLUSTER" apply -f "$EXAMPLE_ROOT/deployment/"
