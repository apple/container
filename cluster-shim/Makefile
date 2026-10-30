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

# Builds cluster-shim as a static Linux binary in bin/. On a Mac, `build`,
# `test` and `protos` run inside a container from ./Dockerfile. On Linux with
# the Static Linux SDK installed, as in CI, `build-native` builds directly.

SWIFT_VERSION := 6.3.0
SWIFT_SDK_URL := https://download.swift.org/swift-6.3-release/static-sdk/swift-6.3-RELEASE/swift-6.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
SWIFT_SDK_CHECKSUM := d2078b69bdeb5c31202c10e9d8a11d6f66f82938b51a4b75f032ccb35c4c286c
# Matches PROTOC_VERSION in the root Protobuf.Makefile.
PROTOC_VERSION := 26.1
BUILD_IMAGE := cluster-shim-build:$(SWIFT_VERSION)
BUILD_VOLUME := cluster-shim-build
ARCH ?= aarch64
SWIFT_SDK := $(ARCH)-swift-linux-musl
SCRATCH_PATH ?= .build/linux
DEST_DIR ?= /usr/local/
# Runs only the install step with elevated rights. Set SUDO= for a writable DEST_DIR.
SUDO ?= sudo
RESOURCES_DIR = $(DEST_DIR)libexec/container/plugins/cluster/resources
ROOT_DIR := $(shell git rev-parse --show-toplevel 2>/dev/null)
CONTAINERD_REPO ?= https://github.com/containerd/containerd.git
# containerd v2.4.2
CONTAINERD_COMMIT := b7a25261e029d68978bbf290df0a62fc819b3c51
CONTAINERD_DIR_IN_REPO := .local/cluster-shim/containerd
CRI_API_REPO ?= https://github.com/kubernetes/cri-api.git
# k8s.io/cri-api v0.37.1
CRI_API_COMMIT := d279f3cbb9d18b653d5fab12e187589914329c77
CRI_API_DIR_IN_REPO := .local/cluster-shim/cri-api

# Fails with instructions when container services are not running.
define require_container
	@container system status > /dev/null 2>&1 || { \
		echo "Error: building cluster-shim needs running container services. Run 'container system start'," >&2; \
		echo "or set CLUSTER_SHIM_BINARY to a binary built on Linux with 'make -C cluster-shim build-native'." >&2; \
		exit 1; }
endef

# Runs a bash command in the build image with the repository at /workspace and
# a persistent build volume at /build.
define linux_run
	$(require_container)
	@container image inspect $(BUILD_IMAGE) > /dev/null 2>&1 || "$(MAKE)" image
	@container volume inspect $(BUILD_VOLUME) > /dev/null 2>&1 || container volume create $(BUILD_VOLUME) > /dev/null
	container run --rm --memory 8g --cpus 8 \
		-v "$(ROOT_DIR)":/workspace \
		-v $(BUILD_VOLUME):/build \
		-w /workspace/cluster-shim \
		$(BUILD_IMAGE) \
		bash -c '$(1)'
endef

.PHONY: image
image:
	$(require_container)
	container build -t $(BUILD_IMAGE) \
		--build-arg SWIFT_VERSION=$(SWIFT_VERSION) \
		--build-arg SWIFT_SDK_URL=$(SWIFT_SDK_URL) \
		--build-arg SWIFT_SDK_CHECKSUM=$(SWIFT_SDK_CHECKSUM) \
		--build-arg PROTOC_VERSION=$(PROTOC_VERSION) \
		-f Dockerfile .

.PHONY: build
build:
	$(call linux_run,make build-native SCRATCH_PATH=/build/scratch)

# ContainerizationOCI imports NIOFoundationCompat without declaring it, so the
# first command builds that module before the full build needs it.
.PHONY: build-native
build-native:
	swift build -c release --swift-sdk $(SWIFT_SDK) --scratch-path $(SCRATCH_PATH) --target NIOFoundationCompat
	swift build -c release --swift-sdk $(SWIFT_SDK) --scratch-path $(SCRATCH_PATH) -Xlinker -s
	mkdir -p bin
	cp "$$(swift build -c release --swift-sdk $(SWIFT_SDK) --scratch-path $(SCRATCH_PATH) --show-bin-path)/cluster-shim" bin/cluster-shim

# Installs the Static Linux SDK for build-native.
.PHONY: linux-sdk
linux-sdk:
	swift sdk install $(SWIFT_SDK_URL) --checksum $(SWIFT_SDK_CHECKSUM)

# Fetches repository $(2) at commit $(3) into $(1) under the repository root,
# inside the build image. Skips the fetch when $(1) is already at $(3).
define fetch_source
	$(call linux_run,set -e; \
		dir=/workspace/$(1); \
		if [ "$$(git -C $$dir rev-parse HEAD 2>/dev/null)" != "$(3)" ]; then \
			echo "Fetching $(2) at $(3)..."; \
			rm -rf $$dir; \
			git init -q $$dir; \
			git -C $$dir fetch -q --depth 1 $(2) $(3); \
			git -C $$dir checkout -q FETCH_HEAD; \
		fi)
endef

# containerd's api/ directory holds the content, images and leases protos.
.PHONY: containerd-source
containerd-source:
	$(call fetch_source,$(CONTAINERD_DIR_IN_REPO),$(CONTAINERD_REPO),$(CONTAINERD_COMMIT))

# cri-api's pkg/apis/runtime/v1/api.proto holds the CRI ImageService.
.PHONY: cri-api-source
cri-api-source:
	$(call fetch_source,$(CRI_API_DIR_IN_REPO),$(CRI_API_REPO),$(CRI_API_COMMIT))

.PHONY: protos
protos: containerd-source cri-api-source
	$(call linux_run,CONTAINERD_API=/workspace/$(CONTAINERD_DIR_IN_REPO)/api CRI_API=/workspace/$(CRI_API_DIR_IN_REPO) ./generate-protos.sh)
	@"$(MAKE)" -C "$(ROOT_DIR)" update-licenses

.PHONY: test
test:
	$(call linux_run,swift build --scratch-path /build/test --target NIOFoundationCompat && swift test --scratch-path /build/test)

.PHONY: install
install: build
	$(SUDO) install -d "$(RESOURCES_DIR)"
	$(SUDO) install -m 0755 bin/cluster-shim "$(RESOURCES_DIR)/cluster-shim"

.PHONY: clean
clean:
	rm -rf bin .build
