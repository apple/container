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

	@install "$(BUILD_BIN_DIR)/container" "$(join $(STAGING_DIR), bin/container)"
	@install "$(BUILD_BIN_DIR)/container-apiserver" "$(join $(STAGING_DIR), bin/container-apiserver)"
	@install "$(BUILD_BIN_DIR)/container-runtime-linux" "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux)"
	@install Sources/Plugins/RuntimeLinux/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/config.toml)"
	@install "$(BUILD_BIN_DIR)/container-network-vmnet" "$(join $(STAGING_DIR), libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet)"
	@install Sources/Plugins/NetworkVmnet/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/container-network-vmnet/config.toml)"
	@install "$(BUILD_BIN_DIR)/container-core-images" "$(join $(STAGING_DIR), libexec/container/plugins/container-core-images/bin/container-core-images)"
	@install Sources/Plugins/CoreImages/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/container-core-images/config.toml)"

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
# Set of files we do not want to get caught in the coverage generation
LLVM_COV_IGNORE := \
	--ignore-filename-regex=".build/" \
	--ignore-filename-regex=".pb.swift" \
	--ignore-filename-regex=".proto" \
	--ignore-filename-regex=".grpc.swift"
# swift test overwrites profraw data on each invocation, so we copy to a safe spot
SAVE_PROFRAW = mkdir -p $(COVERAGE_OUTPUT_DIR)/integration/$(1) && cp $(COV_DATA_DIR)/*.profraw $(COVERAGE_OUTPUT_DIR)/integration/$(1)/

# Generate JSON + HTML coverage reports and a coverage-percent.txt from a profdata file.
# $(1) = profdata path, $(2) = tier name (unit/integration/combined)
define GENERATE_COV_REPORTS
	@echo Exporting $(2) coverage JSON...
	@xcrun llvm-cov export --compilation-dir=`pwd` \
		-instr-profile=$(1) \
		$(LLVM_COV_IGNORE) \
		$(TEST_BINARY) > $(COVERAGE_OUTPUT_DIR)/$(2)/coverage-summary.json
	@echo Generating $(2) coverage HTML report...
	@xcrun llvm-cov show --compilation-dir=`pwd` --format=html \
		-instr-profile=$(1) \
		$(LLVM_COV_IGNORE) \
		-output-dir=$(COVERAGE_OUTPUT_DIR)/$(2)/html \
		$(TEST_BINARY)
	@echo Extracting $(2) coverage percentages...
	@jq -r '"line coverage: \(.data[0].totals.lines.percent * 100 | round / 100)%\nfunction coverage: \(.data[0].totals.functions.percent * 100 | round / 100)%"' \
		$(COVERAGE_OUTPUT_DIR)/$(2)/coverage-summary.json > $(COVERAGE_OUTPUT_DIR)/$(2)/coverage-percent.txt
	@cat $(COVERAGE_OUTPUT_DIR)/$(2)/coverage-percent.txt
endef

INTEGRATION_TEST_SUITES := \
	TestCLIHelp \
	TestCLIStatus \
	TestCLIVersion \
	TestCLINetwork \
	TestCLIRunLifecycle \
	TestCLIRunCapabilities \
	TestCLIExecCommand \
	TestCLICreateCommand \
	TestCLIRunCommand1 \
	TestCLIRunCommand2 \
	TestCLIRunCommand3 \
	TestCLIPruneCommand \
	TestCLIRegistry \
	TestCLIStatsCommand \
	TestCLIImagesCommand \
	TestCLIRunBase \
	TestCLIRunInitImage \
	TestCLIBuildBase \
	TestCLIExportCommand \
	TestCLIVolumes \
	TestCLIKernelSet \
	TestCLIAnonymousVolumes \
	TestCLINotFound \
	TestCLINoParallelCases

.PHONY: coverage
# Merge the raw coverage data generated from coverage-unit and coverage-integration into one unified report
coverage: coverage-unit coverage-integration
	@echo Merging combined coverage profdata...
	@mkdir -p $(COVERAGE_OUTPUT_DIR)/combined
	@xcrun llvm-profdata merge -sparse \
		$(COVERAGE_OUTPUT_DIR)/unit/default.profdata \
		$(COVERAGE_OUTPUT_DIR)/integration/default.profdata \
		-o $(COVERAGE_OUTPUT_DIR)/combined/default.profdata
	$(call GENERATE_COV_REPORTS,$(COVERAGE_OUTPUT_DIR)/combined/default.profdata,combined)

.PHONY: coverage-unit
coverage-unit:
	@echo Running unit test coverage...
	@rm -f $(COV_DATA_DIR)/*.profraw
	@mkdir -p $(COVERAGE_OUTPUT_DIR)/unit
# Run the test suite with profiler (exclude integration tests)
	@$(SWIFT) test --enable-code-coverage -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --skip TestCLI
# Move the profiling data to a staging area for later consumption in full coverage aggregation
	@echo Merging unit coverage profdata...
	@xcrun llvm-profdata merge -sparse $(COV_DATA_DIR)/*.profraw -o $(COVERAGE_OUTPUT_DIR)/unit/default.profdata
# Generate both JSON (for machines) and html (for humans)
	$(call GENERATE_COV_REPORTS,$(COVERAGE_OUTPUT_DIR)/unit/default.profdata,unit)

.PHONY: coverage-integration
coverage-integration: all
	@echo Ensuring apiserver stopped before the coverage integration tests...
	@bin/container system stop && sleep 3 && scripts/ensure-container-stopped.sh
	@echo Running integration test coverage...
	@rm -f $(COV_DATA_DIR)/*.profraw
	@mkdir -p $(COVERAGE_OUTPUT_DIR)/integration
	@bin/container --debug system start --timeout 60 $(SYSTEM_START_OPTS) && \
	echo "Starting CLI integration tests with coverage" && \
	{ \
		exit_code=0; \
		export CLITEST_LOG_ROOT=$(LOG_ROOT) ; \
		$(foreach suite,$(INTEGRATION_TEST_SUITES), \
			$(SWIFT) test --no-parallel --enable-code-coverage -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter $(suite) || exit_code=1 ; $(call SAVE_PROFRAW,$(suite)) ; \
		) \
		echo Ensuring apiserver stopped after the coverage integration tests ; \
		scripts/ensure-container-stopped.sh ; \
		exit $${exit_code} ; \
	}
	@echo Merging integration coverage profdata...
	@xcrun llvm-profdata merge -sparse $(COVERAGE_OUTPUT_DIR)/integration/*/*.profraw -o $(COVERAGE_OUTPUT_DIR)/integration/default.profdata
	$(call GENERATE_COV_REPORTS,$(COVERAGE_OUTPUT_DIR)/integration/default.profdata,integration)

.PHONY: integration
integration: init-block
	@echo Ensuring apiserver stopped before the CLI integration tests...
	@bin/container system stop && sleep 3 && scripts/ensure-container-stopped.sh
	@if [ -n "$(APP_ROOT)" ]; then \
		echo "Clearing application data under $(APP_ROOT) (preserving kernels)..." ; \
		mkdir -p $(APP_ROOT) ; \
		find "$(APP_ROOT)" -mindepth 1 -maxdepth 1 ! -name kernels -exec rm -rf {} + ; \
	fi
	@echo Running the integration tests...
	@bin/container --debug system start --timeout 60 --enable-kernel-install $(SYSTEM_START_OPTS) && \
	echo "Starting CLI integration tests" && \
	{ \
		exit_code=0; \
		CLITEST_LOG_ROOT=$(LOG_ROOT) && export CLITEST_LOG_ROOT ; \
		$(foreach suite,$(INTEGRATION_TEST_SUITES), \
			$(SWIFT) test -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter $(suite) || exit_code=1 ; \
		) \
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
	@rm -rf $(COVERAGE_OUTPUT_DIR)
	@$(SWIFT) package clean
