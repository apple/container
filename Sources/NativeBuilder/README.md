# Swift Native Builder

A pure-Swift container build system leveraging Containerization.framework for fast, secure, and reproducible builds.

## Overview

Swift Native Builder is a modern container build system that replaces traditional container builders with a Swift-native implementation. It runs each build step in isolated VMs, uses content-addressable storage for caching, and produces OCI-compliant container images.

### Key Features

- **Headless** - No daemon required, runs as a simple CLI tool
- **Mac-Native** - Built on Containerization.framework and Swift Concurrency
- **Secure** - Hardware-backed signing with Secure Enclave, biometric-protected secrets
- **Fast** - Parallel execution with intelligent caching

## Quick Start

```bash
# Build a container image
swift run builder build .

# Build with secrets
swift run builder secret add github-token --biometric
swift run builder build --build-secret=id=github-token,target=/run/secrets/token .
```

## Architecture

The project consists of several components:

- **ContainerBuildIR** - Intermediate representation for build operations
- **Parser** - Dockerfile parser and build graph generator
- **Scheduler** - DAG scheduler for parallel execution
- **Executor** - VM-based execution engine
- **CAS** - Content-addressable storage for layers

## Development

```bash
# Build the project
swift build

# Run tests
swift test

# Run demo
swift run container-build-demo
```

## Status

This project is under active development. The IR layer is implemented and functional.