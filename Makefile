# Copyright © 2025-2026 Apple Inc. and the container project authors.
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

# Version and build configuration variables
BUILD_CONFIGURATION ?= debug
WARNINGS_AS_ERRORS ?= true
SWIFT_CONFIGURATION := $(if $(filter-out false,$(WARNINGS_AS_ERRORS)),-Xswiftc -warnings-as-errors)
export RELEASE_VERSION ?= $(shell git describe --tags --always)
export GIT_COMMIT := $(shell git rev-parse HEAD)

# Commonly used locations
SWIFT := "/usr/bin/swift"
DEST_DIR ?= /usr/local/
ROOT_DIR := $(shell git rev-parse --show-toplevel)
BUILD_BIN_DIR = $(shell $(SWIFT) build -c $(BUILD_CONFIGURATION) --show-bin-path)
COV_DATA_DIR = $(shell $(SWIFT) test --show-coverage-path | xargs dirname)
COV_REPORT_FILE = $(ROOT_DIR)/code-coverage-report
STAGING_DIR := bin/$(BUILD_CONFIGURATION)/staging/
PKG_PATH := bin/$(BUILD_CONFIGURATION)/container-installer-unsigned.pkg
DSYM_DIR := bin/$(BUILD_CONFIGURATION)/bundle/container-dSYM
DSYM_PATH := bin/$(BUILD_CONFIGURATION)/bundle/container-dSYM.zip
CODESIGN_OPTS ?= --force --sign - --timestamp=none

# Conditionally use a temporary data directory for integration tests
ifeq ($(strip $(APP_ROOT)),)
	SYSTEM_START_OPTS :=
else
	SYSTEM_START_OPTS := --app-root "$(strip $(APP_ROOT))"
endif

MACOS_VERSION := $(shell sw_vers -productVersion)
MACOS_MAJOR := $(shell echo $(MACOS_VERSION) | cut -d. -f1)

SUDO ?= sudo
.DEFAULT_GOAL := all

include Protobuf.Makefile

.PHONY: all
all: container
all: init-block

.PHONY: build
build:
	@echo Building container binaries...
	@$(SWIFT) --version
	@$(SWIFT) build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION)

.PHONY: cli
cli:
	@echo Building container CLI...
	@$(SWIFT) --version
	@$(SWIFT) build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --product container
	@echo Installing container CLI to bin/...
	@mkdir -p bin
	@install "$(BUILD_BIN_DIR)/container" "bin/container"

.PHONY: container
# Install binaries under project directory
container: build
	@"$(MAKE)" BUILD_CONFIGURATION=$(BUILD_CONFIGURATION) DEST_DIR="$(ROOT_DIR)/" SUDO= install

.PHONY: release
release: BUILD_CONFIGURATION = release
release: all

.PHONY: init-block
init-block:
	@scripts/install-init.sh

.PHONY: install
install: installer-pkg
	@echo Installing container installer package
	@if [ -z "$(SUDO)" ] ; then \
		temp_dir=$$(mktemp -d) ; \
		xar -xf $(PKG_PATH) -C $${temp_dir} ; \
		(cd "$(DEST_DIR)" && pax -rz -f $${temp_dir}/Payload) ; \
		rm -rf $${temp_dir} ; \
	else \
		$(SUDO) installer -pkg $(PKG_PATH) -target / ; \
	fi

$(STAGING_DIR):
	@echo Installing container binaries from "$(BUILD_BIN_DIR)" into "$(STAGING_DIR)"...
	@rm -rf "$(STAGING_DIR)"
	@mkdir -p "$(join $(STAGING_DIR), bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/container-network-vmnet/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/container-core-images/bin)"

	@install "$(BUILD_BIN_DIR)/container" "$(join $(STAGING_DIR), bin/container)"
	@install "$(BUILD_BIN_DIR)/container-apiserver" "$(join $(STAGING_DIR), bin/container-apiserver)"
	@install "$(BUILD_BIN_DIR)/container-runtime-linux" "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux)"
	@install config/container-runtime-linux-config.json "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/config.json)"
	@install "$(BUILD_BIN_DIR)/container-network-vmnet" "$(join $(STAGING_DIR), libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet)"
	@install config/container-network-vmnet-config.json "$(join $(STAGING_DIR), libexec/container/plugins/container-network-vmnet/config.json)"
	@install "$(BUILD_BIN_DIR)/container-core-images" "$(join $(STAGING_DIR), libexec/container/plugins/container-core-images/bin/container-core-images)"
	@install config/container-core-images-config.json "$(join $(STAGING_DIR), libexec/container/plugins/container-core-images/config.json)"

	@echo Install uninstaller script
	@install scripts/uninstall-container.sh "$(join $(STAGING_DIR), bin/uninstall-container.sh)"

.PHONY: installer-pkg
installer-pkg: $(STAGING_DIR)
	@echo Signing container binaries...
	@codesign $(CODESIGN_OPTS) --identifier com.apple.container.cli "$(join $(STAGING_DIR), bin/container)"
	@codesign $(CODESIGN_OPTS) --identifier com.apple.container.apiserver "$(join $(STAGING_DIR), bin/container-apiserver)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. "$(join $(STAGING_DIR), libexec/container/plugins/container-core-images/bin/container-core-images)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. --entitlements=signing/container-runtime-linux.entitlements "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. --entitlements=signing/container-network-vmnet.entitlements "$(join $(STAGING_DIR), libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet)"

	@echo Creating application installer
	@pkgbuild --root "$(STAGING_DIR)" --identifier com.apple.container-installer --install-location /usr/local --version ${RELEASE_VERSION} $(PKG_PATH)
	@rm -rf "$(STAGING_DIR)"

.PHONY: dsym
dsym:
	@echo Copying debug symbols...
	@rm -rf "$(DSYM_DIR)"
	@mkdir -p "$(DSYM_DIR)"
	@cp -a "$(BUILD_BIN_DIR)/container-runtime-linux.dSYM" "$(DSYM_DIR)"
	@cp -a "$(BUILD_BIN_DIR)/container-network-vmnet.dSYM" "$(DSYM_DIR)"
	@cp -a "$(BUILD_BIN_DIR)/container-core-images.dSYM" "$(DSYM_DIR)"
	@cp -a "$(BUILD_BIN_DIR)/container-apiserver.dSYM" "$(DSYM_DIR)"
	@cp -a "$(BUILD_BIN_DIR)/container.dSYM" "$(DSYM_DIR)"

	@echo Packaging the debug symbols...
	@(cd "$(dir $(DSYM_DIR))" ; zip -r $(notdir $(DSYM_PATH)) $(notdir $(DSYM_DIR)))

.PHONY: test
test:
	@$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --skip TestCLI

.PHONY: install-kernel
install-kernel:
	@bin/container system stop || true
	@bin/container system start --enable-kernel-install $(SYSTEM_START_OPTS)

.PHONY: coverage
coverage: init-block
	@echo Ensuring apiserver stopped before the CLI integration tests...
	@bin/container system stop && sleep 3 && scripts/ensure-container-stopped.sh
	@bin/container system start $(SYSTEM_START_OPTS) && \
	echo "Starting unit tests" && \
	{ \
		exit_code=0; \
		$(SWIFT) test --no-parallel --enable-code-coverage -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) || exit_code=1 ; \
		echo Ensuring apiserver stopped after the CLI integration tests ; \
		scripts/ensure-container-stopped.sh ; \
		echo Generating code coverage report... ; \
		xcrun llvm-profdata merge -sparse $(COV_DATA_DIR)/*.profraw -o $(COV_DATA_DIR)/default.profdata ; \
		xcrun llvm-cov show --compilation-dir=`pwd` \
			-instr-profile=$(COV_DATA_DIR)/default.profdata \
			--ignore-filename-regex=".build/" \
			--ignore-filename-regex=".pb.swift" \
			--ignore-filename-regex=".proto" \
			--ignore-filename-regex=".grpc.swift" \
			$(BUILD_BIN_DIR)/containerPackageTests.xctest/Contents/MacOS/containerPackageTests > $(COV_REPORT_FILE) ; \
		echo Code coverage report generated: $(COV_REPORT_FILE) ; \
		exit $${exit_code} ; \
	}

.PHONY: integration
integration: init-block
	@echo Ensuring apiserver stopped before the CLI integration tests...
	@bin/container system stop && sleep 3 && scripts/ensure-container-stopped.sh
	@echo Running the integration tests...
	@bin/container system start $(SYSTEM_START_OPTS) && \
	echo "Starting CLI integration tests" && \
	{ \
		exit_code=0; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLINetwork || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIRunLifecycle || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIExecCommand || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLICreateCommand || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIRunCommand1 || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIRunCommand2 || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIRunCommand3 || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIPruneCommand || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIStatsCommand || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIImagesCommand || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIRunBase || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIRunInitImage || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIBuildBase || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIVolumes || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIKernelSet || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLIAnonymousVolumes || exit_code=1 ; \
		$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter TestCLINoParallelCases || exit_code=1 ; \
		echo Ensuring apiserver stopped after the CLI integration tests ; \
		scripts/ensure-container-stopped.sh ; \
		exit $${exit_code} ; \
	}

.PHONY: fmt
fmt: swift-fmt update-licenses

.PHONY: check
check: swift-fmt-check check-licenses

.PHONY: swift-fmt
SWIFT_SRC = $(shell find . -type f -name '*.swift' -not -path "*/.*" -not -path "*.pb.swift" -not -path "*.grpc.swift" -not -path "*/checkouts/*")
swift-fmt:
	@echo Applying the standard code formatting...
	@$(SWIFT) format --recursive --configuration .swift-format -i $(SWIFT_SRC)

swift-fmt-check:
	@echo Applying the standard code formatting...
	@$(SWIFT) format lint --recursive --strict --configuration .swift-format-nolint $(SWIFT_SRC)

.PHONY: update-licenses
update-licenses:
	@echo Updating license headers...
	@./scripts/ensure-hawkeye-exists.sh
	@.local/bin/hawkeye format --fail-if-unknown --fail-if-updated false

.PHONY: check-licenses
check-licenses:
	@echo Checking license headers existence in source files...
	@./scripts/ensure-hawkeye-exists.sh
	@.local/bin/hawkeye check --fail-if-unknown

.PHONY: pre-commit
pre-commit:
	cp Scripts/pre-commit.fmt .git/hooks
	touch .git/hooks/pre-commit
	cat .git/hooks/pre-commit | grep -v 'hooks/pre-commit\.fmt' > /tmp/pre-commit.new || true
	echo 'PRECOMMIT_NOFMT=$${PRECOMMIT_NOFMT} $$(git rev-parse --show-toplevel)/.git/hooks/pre-commit.fmt' >> /tmp/pre-commit.new
	mv /tmp/pre-commit.new .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit

.PHONY: serve-docs
serve-docs:
	@echo 'to browse: open http://127.0.0.1:8000/container/documentation/'
	@rm -rf _serve
	@mkdir -p _serve
	@cp -a _site _serve/container
	@python3 -m http.server --bind 127.0.0.1 --directory ./_serve

.PHONY: docs
docs:
	@echo Updating API documentation...
	@rm -rf _site
	@scripts/make-docs.sh _site container

.PHONY: cleancontent
cleancontent:
	@bin/container system stop || true
	@echo Cleaning the content...
	@rm -rf ~/Library/Application\ Support/com.apple.container

.PHONY: clean
clean:
	@echo Cleaning build files...
	@rm -rf bin/ libexec/
	@rm -rf _site _serve
	@rm -f $(COV_REPORT_FILE)
	@$(SWIFT) package clean
