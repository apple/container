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
SWIFT_CONFIGURATION := $(if $(filter-out false,$(WARNINGS_AS_ERRORS)),-Xswiftc -warnings-as-errors) -Xswiftc -enable-testing
# Code-coverage instrumentation, layered onto the shared build stages. Empty for
# ordinary builds; the coverage-* targets opt in via a target-specific value so
# only those goals compile instrumented binaries.
COVERAGE_FLAG ?=
export RELEASE_VERSION ?= $(shell git describe --tags --always)
export GIT_COMMIT := $(shell git rev-parse HEAD)

# Commonly used locations
SWIFT := "/usr/bin/swift"
# Shared swift build invocation; callers append --build-tests / --product / etc.
SWIFT_BUILD = $(SWIFT) build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION)
DEST_DIR ?= /usr/local/
ROOT_DIR := $(shell git rev-parse --show-toplevel)
BUILD_BIN_DIR = $(shell $(SWIFT) build -c $(BUILD_CONFIGURATION) --show-bin-path)
STAGING_DIR := bin/$(BUILD_CONFIGURATION)/staging/
PKG_PATH := bin/$(BUILD_CONFIGURATION)/container-installer-unsigned.pkg
DSYM_DIR := bin/$(BUILD_CONFIGURATION)/bundle/container-dSYM
DSYM_PATH := bin/$(BUILD_CONFIGURATION)/bundle/container-dSYM.zip
CODESIGN_OPTS ?= --force --sign - --timestamp=none


# Conditionally use a temporary data directory for integration tests
SYSTEM_START_OPTS :=
ifneq ($(strip $(APP_ROOT)),)
	SYSTEM_START_OPTS += --app-root "$(strip $(APP_ROOT))"
endif
ifneq ($(strip $(LOG_ROOT)),)
	SYSTEM_START_OPTS += --log-root "$(strip $(LOG_ROOT))"
endif

# swift test event-stream JSON output for the concurrent/global integration
# passes, only when LOG_ROOT is set.
CONCURRENT_EVENT_STREAM_OPTS :=
GLOBAL_EVENT_STREAM_OPTS :=
ifneq ($(strip $(LOG_ROOT)),)
	CONCURRENT_EVENT_STREAM_OPTS += --event-stream-output-path "$(strip $(LOG_ROOT))/integration-concurrent.json" --event-stream-version 6.3
	GLOBAL_EVENT_STREAM_OPTS += --event-stream-output-path "$(strip $(LOG_ROOT))/integration-global.json" --event-stream-version 6.3
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
	@$(SWIFT_BUILD)

.PHONY: build-tests
# Shared build stage for every test target: builds the test bundle (and the
# product binaries) once so the test targets can run with --skip-build. This is
# a distinct target from `build` so `make all test` builds products and tests as
# two separate steps rather than colliding on a single once-built target.
# COVERAGE_FLAG instruments the binaries when set by the coverage-* targets.
build-tests:
	@echo Building container binaries and tests...
	@$(SWIFT) --version
	@$(SWIFT_BUILD) --build-tests $(COVERAGE_FLAG)

.PHONY: coverage-all
coverage-all: build-tests
	@"$(MAKE)" BUILD_CONFIGURATION=$(BUILD_CONFIGURATION) DEST_DIR="$(ROOT_DIR)/" SUDO= install
	@"$(MAKE)" init-block

.PHONY: cli
cli:
	@echo Building container CLI...
	@$(SWIFT) --version
	@$(SWIFT_BUILD) --product container
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
	@echo Building initfs if containerization is in edit mode
	@scripts/install-init.sh $(SYSTEM_START_OPTS)

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
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/resources)"

	@install "$(BUILD_BIN_DIR)/container" "$(join $(STAGING_DIR), bin/container)"
	@install "$(BUILD_BIN_DIR)/container-apiserver" "$(join $(STAGING_DIR), bin/container-apiserver)"
	@install "$(BUILD_BIN_DIR)/container-runtime-linux" "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux)"
	@install Sources/Plugins/RuntimeLinux/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/config.toml)"
	@install "$(BUILD_BIN_DIR)/container-network-vmnet" "$(join $(STAGING_DIR), libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet)"
	@install Sources/Plugins/NetworkVmnet/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/container-network-vmnet/config.toml)"
	@install "$(BUILD_BIN_DIR)/container-core-images" "$(join $(STAGING_DIR), libexec/container/plugins/container-core-images/bin/container-core-images)"
	@install Sources/Plugins/CoreImages/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/container-core-images/config.toml)"
	@install "$(BUILD_BIN_DIR)/machine-apiserver" "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/bin/machine-apiserver)"
	@install Sources/Plugins/MachineAPIServer/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/config.toml)"
	@install Sources/Plugins/MachineAPIServer/Resources/init "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/resources/init)"
	@install Sources/Plugins/MachineAPIServer/Resources/create-user.sh "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/resources/create-user.sh)"

	@echo Install update script
	@install scripts/update-container.sh "$(join $(STAGING_DIR), bin/update-container.sh)"
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
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/bin/machine-apiserver)"

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
test: build-tests
	@$(SWIFT) test --skip-build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --skip TestCLI --skip IntegrationTests

.PHONY: install-kernel
install-kernel:
	@echo Stopping system before installing kernel
	@bin/container system stop || true
	@echo Starting system to install kernel
	@bin/container --debug system start --timeout 60 --enable-kernel-install $(SYSTEM_START_OPTS)


# Coverage report generation helpers
# Directory that swift test spits out raw coverage data
COV_DATA_DIR = $(shell $(SWIFT) test --show-coverage-path | xargs dirname)
COV_REPORT_FILE = $(ROOT_DIR)/code-coverage-report
COVERAGE_OUTPUT_DIR := $(ROOT_DIR)/coverage-reports
TEST_BINARY = $(BUILD_BIN_DIR)/containerPackageTests.xctest/Contents/MacOS/containerPackageTests
# All product binaries that may be instrumented for coverage.
# Used as additional -object args to llvm-cov for integration/combined reports.
COV_BINARIES := \
	$(BUILD_BIN_DIR)/container \
	$(BUILD_BIN_DIR)/container-apiserver \
	$(BUILD_BIN_DIR)/container-runtime-linux \
	$(BUILD_BIN_DIR)/container-network-vmnet \
	$(BUILD_BIN_DIR)/container-core-images \
	$(BUILD_BIN_DIR)/machine-apiserver
COV_OBJECT_FLAGS := $(patsubst %,-object %,$(COV_BINARIES))
# Set of files we do not want to get caught in the coverage generation
LLVM_COV_IGNORE := \
	--ignore-filename-regex=".build/" \
	--ignore-filename-regex="/Tests/" \
	--ignore-filename-regex="/ContainerTestSupport/" \
	--ignore-filename-regex=".pb.swift" \
	--ignore-filename-regex=".proto" \
	--ignore-filename-regex=".grpc.swift"

# Generate JSON + HTML coverage reports and a coverage-percent.txt from a profdata file.
# $(1) = profdata path, $(2) = tier name (unit/integration/combined), $(3) = additional -object flags (optional)
define GENERATE_COV_REPORTS
	@echo Exporting $(2) coverage JSON...
	@xcrun llvm-cov export --compilation-dir=`pwd` \
		-instr-profile=$(1) \
		$(LLVM_COV_IGNORE) \
		$(TEST_BINARY) $(3) > $(COVERAGE_OUTPUT_DIR)/$(2)/coverage-summary.json
	@echo Generating $(2) coverage HTML report...
	@xcrun llvm-cov show --compilation-dir=`pwd` --format=html \
		-instr-profile=$(1) \
		$(LLVM_COV_IGNORE) \
		-output-dir=$(COVERAGE_OUTPUT_DIR)/$(2)/html \
		$(TEST_BINARY) $(3)
	@echo Extracting $(2) coverage percentages...
	@jq -r '.data[0].totals as $$t | \
		"Coverage summary:", \
		"  lines:     \($$t.lines.percent | . * 100 | round | . / 100)% (\($$t.lines.covered) of \($$t.lines.count))", \
		"  functions: \($$t.functions.percent | . * 100 | round | . / 100)% (\($$t.functions.covered) of \($$t.functions.count))", \
		"  regions:   \($$t.regions.percent | . * 100 | round | . / 100)% (\($$t.regions.covered) of \($$t.regions.count))"' \
		$(COVERAGE_OUTPUT_DIR)/$(2)/coverage-summary.json > $(COVERAGE_OUTPUT_DIR)/$(2)/coverage-percent.txt
	@echo "-- $(2) coverage --"
	@cat $(COVERAGE_OUTPUT_DIR)/$(2)/coverage-percent.txt
endef

# PARALLEL_WIDTH controls --experimental-maximum-parallelization-width for the
# concurrent pass. WARMUP_FILTER, BUILDER_WARMUP_FILTER, CONCURRENT_FILTER, and
# SERIAL_FILTER select the phases.
#
# BuilderWarmup runs as its own sequential step, after WARMUP_FILTER and before
# the concurrent pass, rather than folded into WARMUP_FILTER: swift-testing
# parallelizes suites within one `swift test` invocation by default, and
# racing the builder's image fetch/VM boot against ImageWarmup's concurrent
# image pulls starved a launchd helper spawn long enough to blow past its XPC
# timeout on CI.
PARALLEL_WIDTH ?= $(shell sysctl -n hw.physicalcpu)
WARMUP_FILTER = ImageWarmup/
BUILDER_WARMUP_FILTER = BuilderWarmup/

# Concurrent suites: Test*.swift files whose names do NOT end in Serial.
CONCURRENT_TEST_SUITES ?= $(sort $(addsuffix /,$(basename $(notdir \
    $(shell find Tests/IntegrationTests -name 'Test*.swift' \
            ! -name '*Serial.swift' 2>/dev/null)))))
CONCURRENT_FILTER = $(subst $(space),|,$(strip $(CONCURRENT_TEST_SUITES)))

# Serial suites: Test*.swift files whose names end in Serial.
SERIAL_TEST_SUITES ?= $(sort $(addsuffix /,$(basename $(notdir \
    $(shell find Tests/IntegrationTests -name 'Test*Serial.swift' 2>/dev/null)))))
SERIAL_FILTER = $(subst $(space),|,$(strip $(SERIAL_TEST_SUITES)))

INTEGRATION_SWIFT_EXTRA ?=
INTEGRATION_POST_TEST ?=
# Environment prefix applied to the `container system start` invocation. Empty for
# ordinary runs; coverage runs set LLVM_PROFILE_FILE here so launchd-managed helper
# (XPC service) processes emit their own profraw data.
INTEGRATION_PROFILE_ENV ?=

PRESERVE_KERNELS ?= false
# Default scratch root under the project directory so container build can access context
# subdirectories (macOS restricts access to /var/folders from the container binary).
# Override with SCRATCH_ROOT=/your/path on the command line.
SCRATCH_ROOT ?= $(ROOT_DIR)/.test-scratch

define RUN_INTEGRATION
	@echo Ensuring apiserver stopped before the CLI integration tests...
	@bin/container system stop && sleep 3 && scripts/ensure-container-stopped.sh
	@if [ -n "$(APP_ROOT)" ]; then \
		mkdir -p $(APP_ROOT) ; \
		if [ "$(PRESERVE_KERNELS)" = "true" ]; then \
			echo "Clearing application data under $(APP_ROOT) (preserving kernels)..." ; \
			find "$(APP_ROOT)" -mindepth 1 -maxdepth 1 ! -name kernels -exec rm -rf {} + ; \
		else \
			echo "Clearing application data under $(APP_ROOT)..." ; \
			find "$(APP_ROOT)" -mindepth 1 -maxdepth 1 -exec rm -rf {} + ; \
		fi ; \
	fi
	@echo Running the integration tests...
	@$(INTEGRATION_PROFILE_ENV) bin/container --debug system start --timeout 60 --enable-kernel-install $(SYSTEM_START_OPTS) && \
	{ \
		if [ -n "$(APP_ROOT)" ]; then CONTAINER_APP_ROOT=$(APP_ROOT) && export CONTAINER_APP_ROOT ; fi ; \
		CLITEST_LOG_ROOT=$(LOG_ROOT) && export CLITEST_LOG_ROOT ; \
		CLITEST_SCRATCH_ROOT=$(SCRATCH_ROOT) && export CLITEST_SCRATCH_ROOT ; \
		CONTAINER_CLI_PATH=$(ROOT_DIR)/bin/container && export CONTAINER_CLI_PATH ; \
		echo "==> Warmup pass" && \
		$(SWIFT) test $(INTEGRATION_SWIFT_EXTRA) -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter "$(WARMUP_FILTER)" && \
		echo "==> Builder warmup pass" && \
		$(SWIFT) test $(INTEGRATION_SWIFT_EXTRA) -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter "$(BUILDER_WARMUP_FILTER)" && \
		echo "==> Concurrent pass (width=$(PARALLEL_WIDTH))" && \
		$(SWIFT) test $(INTEGRATION_SWIFT_EXTRA) -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) $(CONCURRENT_EVENT_STREAM_OPTS) --experimental-maximum-parallelization-width $(PARALLEL_WIDTH) --filter "$(CONCURRENT_FILTER)" && \
		echo "==> Global pass (serial)" && \
		$(SWIFT) test $(INTEGRATION_SWIFT_EXTRA) -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) $(GLOBAL_EVENT_STREAM_OPTS) --experimental-maximum-parallelization-width 1 --filter "$(SERIAL_FILTER)" ; \
		exit_code=$$? ; \
		$(INTEGRATION_POST_TEST) \
		echo Ensuring apiserver stopped after the CLI integration tests ; \
		scripts/ensure-container-stopped.sh ; \
		exit $${exit_code} ; \
	}
endef

.PHONY: integration
integration: init-block
	@echo "HOSTNAME: $$(hostname)"
	$(RUN_INTEGRATION)

.PHONY: coverage-integration
coverage-integration: INTEGRATION_SWIFT_EXTRA = --skip-build --enable-code-coverage
coverage-integration: INTEGRATION_POST_TEST = cp $(COV_DATA_DIR)/*.profraw $(COVERAGE_OUTPUT_DIR)/integration/ || true ;
# Continuous mode (%c) mmaps the profraw and syncs counters live. The XPC helper
# services are torn down by `launchctl bootout` (SIGTERM/SIGKILL) rather than
# exiting cleanly, so a non-continuous profile (written by an atexit handler that
# never runs on SIGKILL) would lose the helpers' counters. %p-%m keeps each
# process/module profile in its own file so they don't collide.
coverage-integration: INTEGRATION_PROFILE_ENV = LLVM_PROFILE_FILE=$(COVERAGE_OUTPUT_DIR)/integration/%p-%m%c.profraw
coverage-integration: coverage-all
	@echo "HOSTNAME: $$(hostname)"
	@mkdir -p $(COVERAGE_OUTPUT_DIR)/integration
	@rm -f $(COVERAGE_OUTPUT_DIR)/integration/*.profraw
	$(RUN_INTEGRATION)
	@echo Merging integration coverage profdata...
	@xcrun llvm-profdata merge -sparse $(COVERAGE_OUTPUT_DIR)/integration/*.profraw -o $(COVERAGE_OUTPUT_DIR)/integration/default.profdata
	$(call GENERATE_COV_REPORTS,$(COVERAGE_OUTPUT_DIR)/integration/default.profdata,integration,$(COV_OBJECT_FLAGS))

empty :=
space := $(empty) $(empty)

# Opt the coverage targets in to instrumentation. The value propagates to the
# shared build-tests target so compilation is instrumented when necessary.
coverage coverage-all coverage-unit coverage-integration: COVERAGE_FLAG = --enable-code-coverage -Xswiftc -DCONTAINER_COVERAGE

.PHONY: coverage
# Merge the per-tier profdata from coverage-unit and coverage-integration into a
# combined report. Each prerequisite target produces its own tier report first.
coverage: coverage-unit coverage-integration
	@echo Merging combined coverage profdata...
	@mkdir -p $(COVERAGE_OUTPUT_DIR)/combined
	@xcrun llvm-profdata merge -sparse \
		$(COVERAGE_OUTPUT_DIR)/unit/default.profdata \
		$(COVERAGE_OUTPUT_DIR)/integration/default.profdata \
		-o $(COVERAGE_OUTPUT_DIR)/combined/default.profdata
	$(call GENERATE_COV_REPORTS,$(COVERAGE_OUTPUT_DIR)/combined/default.profdata,combined,$(COV_OBJECT_FLAGS))

.PHONY: coverage-unit
coverage-unit: build-tests
	@echo Running unit test coverage...
	@rm -f $(COV_DATA_DIR)/*.profraw
	@mkdir -p $(COVERAGE_OUTPUT_DIR)/unit
	@$(SWIFT) test --skip-build --enable-code-coverage -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --skip TestCLI --skip IntegrationTests
	@echo Merging unit coverage profdata...
	@xcrun llvm-profdata merge -sparse $(COV_DATA_DIR)/*.profraw -o $(COVERAGE_OUTPUT_DIR)/unit/default.profdata
	$(call GENERATE_COV_REPORTS,$(COVERAGE_OUTPUT_DIR)/unit/default.profdata,unit)

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
	$(eval HOOKS_DIR := $(shell git rev-parse --git-path hooks))
	cp scripts/pre-commit.fmt $(HOOKS_DIR)/
	touch $(HOOKS_DIR)/pre-commit
	cat $(HOOKS_DIR)/pre-commit | grep -v 'hooks/pre-commit\.fmt' > /tmp/pre-commit.new || true
	echo 'PRECOMMIT_NOFMT=$${PRECOMMIT_NOFMT} $$(git rev-parse --git-path hooks/pre-commit.fmt)' >> /tmp/pre-commit.new
	mv /tmp/pre-commit.new $(HOOKS_DIR)/pre-commit
	chmod +x $(HOOKS_DIR)/pre-commit
	@./scripts/ensure-hawkeye-exists.sh

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
	@rm -rf $(COVERAGE_OUTPUT_DIR)
	@$(SWIFT) package clean
