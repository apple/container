# Compose Feature Brief

> [!IMPORTANT]
> This file contains documentation for the CURRENT BRANCH. To find documentation for official releases, find the target release on the [Release Page](https://github.com/apple/container/releases) and click the tag corresponding to your release version.

## Overview

`container compose` adds first-class multi-service workflow support to the `container` CLI for common local-development Compose projects.

The goal of the feature is not full Docker Compose parity. The goal is to make existing `compose.yaml` style application setups usable on top of the `container` runtime and networking model, with clear validation for unsupported fields instead of silent partial behavior.

## What We Added

The CLI now supports:

* `container compose config`
* `container compose up`
* `container compose down`
* `container compose ps`
* `container compose logs`

The command discovers these default filenames in order:

```bash
compose.yaml
compose.yml
docker-compose.yaml
docker-compose.yml
```

Supported MVP fields include:

* Top-level: `name`, `services`, `networks`, `volumes`
* Service: `image`, `build.context`, `build.dockerfile`, `build.args`, `build.target`, `command`, `entrypoint`, `environment`, `env_file`, `ports`, `volumes`, `depends_on`, `depends_on.condition`, `networks`, `working_dir`, `user`, `tty`, `stdin_open`, `profiles`, `healthcheck`

Unsupported fields fail validation with explicit errors.

## Implementation Summary

The feature is implemented directly inside the CLI rather than as a plugin or separate daemon API.

### Compose parsing and normalization

The Compose loader reads YAML, interpolates environment variables, validates unsupported keys, and normalizes the project into an internal execution model.

Important normalization choices:

* named volumes become project-scoped volume names such as `<project>_<volume>`
* named networks become project-scoped network names such as `<project>_<network>`
* services are ordered topologically from `depends_on`
* `depends_on.condition` currently supports `service_started` and `service_healthy`
* service `command` and `entrypoint` strings are tokenized into executable arguments without implicit shell wrapping

That last point matters because Compose string commands do not behave like a Dockerfile shell-form `CMD`. This implementation had to preserve cases such as:

* `command: server /data --console-address ":9001"`
* `entrypoint: /bin/sh -c "some setup command"`

### Runtime translation

Compose services are translated into existing `container` runtime primitives.

Each service becomes a single container with Compose-specific labels:

* `com.apple.container.compose.project`
* `com.apple.container.compose.service`
* `com.apple.container.compose.version`
* `com.apple.container.compose.config-hash`

The executor then:

* creates project networks and volumes
* builds images when needed
* creates containers with deterministic names
* starts services in dependency order
* waits for dependency readiness when `depends_on.condition` requires it

### Healthchecks and startup ordering

`service_started` waits for the dependency container to reach a running state.

`service_healthy` runs the dependency healthcheck inside the target container and retries according to the Compose healthcheck definition.

This support was needed for real-world workflows where a short-lived setup service should only start after a backing service is ready.

### Service-name networking

Compose services expect other services to be reachable by service name on the project network.

To make that work on top of the `container` network model, Compose-attached containers are given network hostnames based on the Compose service name rather than only the generated container name. That allows service-to-service resolution like:

* `minio-create-bucket -> minio`
* `web -> db`

## Practical Example

The feature was validated against a real multi-service project with:

* PostgreSQL
* MinIO
* a one-shot MinIO bucket bootstrap service

That validation drove several correctness fixes:

* healthcheck support
* `depends_on.condition` support
* safe construction of parser-backed CLI flag models inside internal code paths
* proper tokenization of Compose string commands and entrypoints
* network hostnames based on Compose service names

## Limitations

This is still an MVP local-development implementation, not full Docker Compose compatibility.

Known limits include:

* one container per service
* no scaling or replicas
* unsupported fields still fail validation
* no broad parity for advanced production-oriented Compose features
* limited lifecycle semantics for one-shot services beyond start ordering and readiness

## Testing and Validation

The feature has both normalization tests and CLI-level regression tests.

Coverage includes:

* file discovery
* interpolation
* unsupported-key validation
* healthcheck parsing
* `depends_on.condition`
* string command and entrypoint tokenization
* `compose up` regression for parser-backed initialization bugs
* service-name DNS resolution across the project network

In addition to test coverage, the feature was validated manually against a real Compose project to confirm:

* long-running services stay running
* one-shot setup services run and stop cleanly
* dependent services can resolve each other by Compose service name

## Brief Summary

`container compose` brings practical multi-service local development to the `container` CLI by translating a supported subset of Compose into native `container` runtime, networking, and volume operations. The implementation intentionally favors explicit validation, deterministic naming, and runtime correctness over silent partial compatibility. The result is a usable Compose workflow for real application stacks, with enough guardrails to make unsupported behavior obvious.
