# Container Compose Plugin

This plugin provides docker-compose functionality for Apple Container, allowing you to define and run multi-container applications using familiar docker-compose YAML syntax.

## Features

- **Service Orchestration**: Define and run multi-container applications
- **Build Support**: Automatically build Docker images from Dockerfiles
- **Dependency Management**: Handle service dependencies and startup order
- **Volume Management**: Support for named volumes and bind mounts
- **Network Configuration**: Automatic network setup and service discovery
- **Health Checks**: Built-in health check support
- **Environment Variables**: Flexible environment variable handling

## Building

From the plugin directory:
```bash
swift build
```

From the main project root:
```bash
make plugin-compose
```

## Installation

The plugin is automatically installed when you build and install the main container project:
```bash
make install
```

The plugin will be installed to:
```
/usr/local/libexec/container/plugins/compose/
```

## Usage

Once installed, the plugin integrates seamlessly with the container CLI:
```bash
container compose up
container compose down
container compose ps
# etc.
```

## Build Support

The plugin now supports building Docker images directly from your compose file:

```yaml
version: '3.8'
services:
  backend:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        NODE_ENV: production
    ports:
      - "8000:8000"

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile.dev
    ports:
      - "3000:3000"
```

When you run `container compose up`, the plugin will:
1. Automatically detect services with `build:` configurations
2. Build Docker images using Apple Container's native build system
3. Tag images deterministically (SHA‑256 fingerprint) and start containers from those images
4. Cache builds to avoid unnecessary rebuilds

### Build Configuration Options

- `context`: Build context directory (default: ".")
- `dockerfile`: Path to Dockerfile (default: "Dockerfile")
- `args`: Build arguments as key-value pairs

### Build Caching

The plugin implements intelligent build caching based on:
- Build context directory
- Dockerfile path and content
- Build arguments

Services with unchanged build configurations reuse cached images using a stable SHA‑256 key derived from context, dockerfile path, and build args.

### Image Tagging Semantics

- If a service specifies both `build:` and `image: <name>`, the plugin builds the image and tags it as `<name>` (matching Docker Compose behavior).
- If a service specifies `build:` without `image:`, the plugin computes a deterministic tag based on the project, service name, build context, Dockerfile path, and build args:
  - Tag format: `<project>_<service>:<fingerprint>` where `<fingerprint>` is a stable short hash.
  - This ensures the name used at runtime matches what was built.

## Runtime Labels and Recreate Policy

- Containers created by the plugin have labels:
  - `com.apple.compose.project`, `com.apple.compose.service`, `com.apple.compose.container`
  - `com.apple.container.compose.config-hash`: SHA‑256 fingerprint of the effective runtime config (image, cmd/args, workdir, env, ports, mounts, resources, user-provided labels, healthcheck).
- On `compose up`:
  - `--no-recreate`: reuses an existing container for the service.
  - default: compares the expected config hash to the existing container’s label and reuses if equal; otherwise, recreates.
  - `--force-recreate`: always recreates.

## Commands

- `compose up`:
   - Builds images as needed, honoring `build:` and `image:`.
   - Prints service image tags and DNS names.
   - `--remove-orphans`: removes containers from the same project that are no longer defined (prefers labels; falls back to name prefix).
   - `--rm`: automatically removes containers when they exit.
- `compose down`:
  - Stops and removes containers for the project, prints a summary of removed containers and volumes.
  - `--remove-orphans`: also removes any extra containers matching the project.
  - `--volumes`: removes non-external named volumes declared by the project.
- `compose ps`:
  - Lists runtime container status (ID, image, status, ports), filtered by project using labels or name prefix.
- `compose logs`:
  - Streams logs for selected services or all services by project, with service name prefixes. Supports `--follow`, `--tail` (best-effort), and `-t/--timestamps` formatting in CLI.
- `compose exec`:
  - Executes a command in a running service container (`-i`, `-t`, `-u`, `-w`, `-e` supported). Detach returns immediately; otherwise returns the exit code of the command.

## Environment Variables

- The plugin loads variables from `.env` for compose file interpolation (matching Docker Compose precedence):
  - CLI loads from the current working directory.
  - Parser loads from the directory of the compose file when parsing by URL.
- Precedence: shell environment overrides `.env` values. Variables already set in the environment are not overwritten by `.env`.
- You can also pass variables explicitly with `--env KEY=VALUE` (repeatable).
- `.env` loading is applied consistently across commands: `up`, `down`, `ps`, `start`, `logs`, `exec`, `validate`.
- Security: the loader warns if `.env` is group/other readable; consider `chmod 600 .env`.

## Compatibility and Limitations

- YAML anchors and merge keys are disabled by default for hardening. You can enable them with `--allow-anchors` on compose commands.
- Health gating and container recreation flags (`--force-recreate`, `--no-recreate`) are not fully implemented yet.
- `ps`, `logs`, and `exec` implementations are limited and may not reflect full runtime state.

## Documentation

See COMPOSE.md for detailed documentation on supported features and usage.

## Development

The plugin follows the standard Apple Container plugin architecture:
- `config.json` - Plugin metadata and configuration
- `Sources/CLI/` - Command-line interface implementation
- `Sources/Core/` - Core compose functionality (parser, orchestrator, etc.)
- `Tests/` - Unit and integration tests

## Testing

Run tests from the plugin directory:
```bash
swift test
```
