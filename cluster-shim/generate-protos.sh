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

# Generates Sources/ClusterShim/Generated from the containerd protos under
# CONTAINERD_API (containerd's api/ directory) and the CRI api.proto under
# CRI_API (the cri-api repository), both fetched by `make protos`. Runs inside
# the build image, which provides protoc; the Swift plugins are built from this
# package's dependencies.

set -euo pipefail

: "${CONTAINERD_API:?set CONTAINERD_API to the containerd api directory}"
: "${CRI_API:?set CRI_API to the cri-api repository directory}"

TOOLS=/build/tools
swift build -c release --product protoc-gen-swift --scratch-path "${TOOLS}"
swift build -c release --product protoc-gen-grpc-swift-2 --scratch-path "${TOOLS}"
BIN=$(swift build -c release --scratch-path "${TOOLS}" --show-bin-path)

OUT=Sources/ClusterShim/Generated
rm -f "${OUT}"/*.swift

generate() {
    local proto_path=$1
    shift
    protoc \
        --plugin=protoc-gen-swift="${BIN}/protoc-gen-swift" \
        --plugin=protoc-gen-grpc-swift="${BIN}/protoc-gen-grpc-swift-2" \
        --proto_path="${proto_path}" \
        --proto_path=/usr/local/include \
        --swift_out="${OUT}" \
        --swift_opt=FileNaming=PathToUnderscores \
        --grpc-swift_out="${OUT}" \
        --grpc-swift_opt=FileNaming=PathToUnderscores \
        "$@"
}

generate "${CONTAINERD_API}" \
    types/descriptor.proto \
    services/content/v1/content.proto \
    services/images/v1/images.proto \
    services/leases/v1/leases.proto
# cluster-shim serves only the CRI ImageService, so the RuntimeService is
# removed from a copy of api.proto before generating.
CRI_PROTOS=/build/protos/cri
rm -rf "${CRI_PROTOS}"
mkdir -p "${CRI_PROTOS}/runtime/v1"
awk '/^service RuntimeService \{/ { skip = 1 } !skip { print } skip && /^\}/ { skip = 0 }' \
    "${CRI_API}/pkg/apis/runtime/v1/api.proto" > "${CRI_PROTOS}/runtime/v1/api.proto"
generate "${CRI_PROTOS}" runtime/v1/api.proto
