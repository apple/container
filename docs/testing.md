# Testing / 测试指南

> [!IMPORTANT]
> This file contains documentation for the CURRENT BRANCH.

This guide explains how to set up and run tests for the `container` project.

本文档说明如何设置和运行 `container` 项目的测试。

## Prerequisites / 前提条件

- Mac with Apple silicon
- macOS 26 (recommended) or macOS 15
- Xcode 26, set as the [active developer directory](https://developer.apple.com/library/archive/technotes/tn2339/_index.html#//apple_ref/doc/uid/DTS40014588-CH1-HOW_DO_I_SELECT_THE_DEFAULT_VERSION_OF_XCODE_TO_USE_FOR_MY_COMMAND_LINE_TOOLS_)

## Quick Start / 快速开始

### 1. Automated setup (recommended) / 自动设置（推荐）

```bash
# Full setup: build + install kernel + start system
./scripts/setup-test-env.sh

# Run all tests
swift test
```

### 2. Manual setup / 手动设置

```bash
# Build the project
make all

# Install CLI binary to bin/container (required by tests)
make cli

# Start the system (will prompt for kernel install)
container system start

# Run unit tests (skips integration tests requiring container system)
make test

# Run all tests including integration tests
swift test
```

### 3. Setup with isolated data directory / 使用隔离数据目录

```bash
# Use a temporary directory to avoid affecting your system
./scripts/setup-test-env.sh --app-root /tmp/container-test --log-root /tmp/container-test-logs

# Run tests with custom app-root
APP_ROOT=/tmp/container-test swift test
```

## Test Structure / 测试结构

```
Tests/
├── CLITests/                    # CLI integration tests (需运行 container system)
│   ├── Subcommands/
│   │   ├── Build/               # Build command tests
│   │   ├── Containers/          # Container lifecycle tests
│   │   ├── Images/              # Image management tests
│   │   ├── Machine/             # Container machine tests
│   │   ├── Networks/            # Network management tests
│   │   ├── Plugins/             # Plugin system tests
│   │   ├── Registry/            # Registry operation tests
│   │   ├── Run/                 # Container run tests
│   │   ├── System/              # System command tests (kernel, etc.)
│   │   └── Volumes/             # Volume management tests
│   ├── Utilities/
│   │   └── CLITest.swift        # Test base class and helpers
│   ├── TestCLIHelp.swift        # Help output tests
│   └── TestCLINoParallelCases.swift
├── ContainerAPIClientTests/
├── ContainerAPIServiceTests/
├── ContainerBuildTests/
├── ContainerNetworkServerTests/
├── ContainerPersistenceTests/
├── ContainerPluginTests/
├── ContainerResourceTests/
├── ContainerVersionTests/
├── DNSServerTests/
├── SocketForwarderTests/
└── TerminalProgressTests/
```

## Test Types / 测试类型

### Unit Tests / 单元测试

Run without any system dependencies:

```bash
swift test --filter "CLITests" --filter "ContainerResourceTests" --filter "ContainerPersistenceTests"
```

Or skip all CLI integration tests:

```bash
make test
```

### Integration Tests / 集成测试

CLI tests require a running `container system` with a kernel installed. These are run as part of `swift test`.

**Common issues:**

| Symptom / 症状 | Cause / 原因 | Solution / 解决 |
|---------------|-------------|----------------|
| `.binaryNotFound` | Kernel not installed | `./scripts/setup-test-env.sh` |
| `Container not found` | Container system not running | `container system start` |
| `XPC connection error` | Background services not started | `container system start` |
| `Download timeout` | Network issue downloading kernel | Check network or use `--skip-kernel` with pre-installed kernel |

## Configuration / 配置

### Environment Variables / 环境变量

| Variable / 变量 | Purpose / 用途 | Default / 默认值 |
|---------------|---------------|-----------------|
| `CONTAINER_CLI_PATH` | Path to container binary for tests | `bin/container` in project root |
| `CLITEST_LOG_ROOT` | Directory for test logs | Disabled |
| `APP_ROOT` | Application data root | System default |
| `LOG_ROOT` | Log file root | System default |
| `BUILD_CONFIGURATION` | Swift build configuration | `debug` |

### Test-Only Configuration / 仅测试配置

You can override default settings for tests by creating a test-specific TOML config:

```toml
# ~/.config/container/config.toml (user config)
# or $APP_ROOT/config.toml (app-root config)

[build]
cpus = 4
memory = "4gb"

[container]
cpus = 2
memory = "1gb"

[kernel]
# Custom kernel URL for testing
url = "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst"
binaryPath = "opt/kata/share/kata-containers/vmlinux-6.18.15-186"
```

## Debugging Test Failures / 调试测试失败

### Checking Logs / 查看日志

```bash
# View test logs (if CLITEST_LOG_ROOT is set)
tail -f $CLITEST_LOG_ROOT/clitests/TestCLIKernelSet/fromLocalTar.log

# View system logs
container system logs
```

### Running a Single Test / 运行单个测试

```bash
swift test --filter "TestCLIKernelSet/fromLocalTar"
```

### Kernel Test Debugging / 内核测试调试

The kernel set tests (`TestCLIKernelSet`) require:

1. A valid kernel archive (auto-downloaded from GitHub releases)
2. The correct binary path within the archive
3. System started with `container system start`

To manually install a kernel for testing:

```bash
# Download and install the recommended kernel
container system kernel set --recommended

# Or install from a local tar file
container system kernel set --force --tar /path/to/kata-static.tar.zst --binary opt/kata/share/kata-containers/vmlinux-<version>
```
