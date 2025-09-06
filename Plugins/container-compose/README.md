# Container Compose Plugin

This plugin provides docker-compose functionality for Apple Container, allowing you to define and run multi-container applications using familiar docker-compose YAML syntax.

## Features

- **Service Orchestration**: Define and run multi-container applications
- **Build Support**: Automatically build Docker images from Dockerfiles
- **Dependency Management**: Handle service dependencies and startup order
- **Volume Management**: Bind mounts, named volumes, and anonymous volumes (bare `/path`)
- **Network Configuration**: Automatic network setup and service discovery
- **Health Checks**: Built-in health check support
- **Environment Variables**: Flexible environment variable handling
- **Compose Parity Additions**:
  - Build target (`build.target`) forwarded to container build `--target`
  - Port range mapping (e.g. `4510-4559:4510-4559[/proto]` expands to discrete rules)
  - Long-form volumes: `type` bind/volume/tmpfs, `~` expansion, relative → absolute normalization, supports `ro|rw|z|Z|cached|delegated`
  - Entrypoint/Cmd precedence: image Entrypoint/Cmd respected; service `entrypoint`/`command` override; `entrypoint: ''` clears image entrypoint
  - `tty` and `stdin_open` respected (`tty` → interactive terminal; `stdin_open` → keep STDIN open)
  - Image pulling policy on `compose up --pull` with `always|missing|never`
  - Health gating with `depends_on` conditions and `--wait/--wait-timeout`

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

### New flags (parity with Docker Compose)

- `--pull <policy>`: `always|missing|never` — controls image pull behavior during `up`.
- `--wait`: block until services reach running/healthy state.
- `--wait-timeout <seconds>`: maximum wait time for `--wait`.

## Volume and Mount Semantics

The plugin aligns closely with Docker Compose while mapping to Apple Container’s runtime primitives. There are three user‑facing mount types you can declare in compose; internally they map to two host mechanisms:

- Host directory share (virtiofs)
- Managed block volume (ext4)

### 1) Bind Mounts (host directories)

- Compose syntax:
  - Short: `./host_path:/container/path[:ro]`, `~/dir:/container/path`, `/abs/host:/container/path`
  - Long: `type: bind`, `source: ./dir`, `target: /container/path`, `read_only: true`
- Normalization:
  - `~` expands to your home directory.
  - Relative paths resolve to absolute paths using the working directory.
- Runtime mapping:
  - Mapped as a virtiofs share from the host path to the container path.
  - Read‑only honored via `:ro` or `read_only: true`.
- Notes:
  - Options like `:cached`, `:delegated`, SELinux flags `:z`/`:Z` are accepted in YAML but currently do not alter behavior; the mount is still a virtiofs host share.

### 2) Named Volumes

- Compose syntax:
  - Short: `myvol:/container/path[:ro]`
  - Long: `type: volume`, `source: myvol`, `target: /container/path`
  - Define in top‑level `volumes:` (optional if not `external: true`).
- Runtime mapping:
  - The orchestrator ensures the volume exists (creates if missing and not external), then mounts it using Apple Container’s managed block volume (ext4) and its host mountpoint.
  - Labels set on created volumes: `com.apple.compose.project`, `com.apple.compose.service`, `com.apple.compose.target`, `com.apple.compose.anonymous=false`.
- Cleanup:
  - `container compose down --volumes` removes non‑external volumes declared in the project.

### 3) Anonymous Volumes (bare container paths)

- Compose syntax:
  - Short: `- /container/path`
  - Long (equivalent semantics): `type: volume`, `target: /container/path` with no `source`.
- Runtime mapping:
  - Treated as a named volume with a deterministic generated name: `<project>_<service>_anon_<hash>`.
  - Created if missing and mounted as a managed block volume (ext4) using the volume’s host mountpoint.
  - Labeled with `com.apple.compose.anonymous=true` for lifecycle management.
- Cleanup:
  - `container compose down --volumes` also removes these anonymous volumes (matched via labels).

### 4) Tmpfs (container‑only memory mount)

- Compose long form only: `type: tmpfs`, `target: /container/tmp`, `read_only: true|false`.
- Runtime mapping:
  - An in‑memory tmpfs mount at the container path.

### Behavior Summary

- Bind mount → virtiofs host share (best for live dev against host files).
- Named/anonymous volume → managed block volume (best for persisted container data independent of your working tree).
- Tmpfs → in‑memory ephemeral mount.

### Port Publishing (for completeness)

- Compose `ports:` entries like `"127.0.0.1:3000:3000"`, `"3000:3000"` are supported.
- The runtime binds the host address/port and forwards to the container IP/port using a TCP/UDP forwarder.

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
- `target`: Build stage to use as final image (forwarded to `container build --target`).

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
   - `--pull`: image pulling policy (`always|missing|never`).
   - `--wait`, `--wait-timeout`: wait for running/healthy states (healthy if `healthcheck` exists; running otherwise).
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

### Environment semantics and validation

- Accepts both dictionary and list forms under `environment:`.
- List items must be `KEY=VALUE`; unsupported forms are rejected.
- Variable names must match `^[A-Za-z_][A-Za-z0-9_]*$`.
- Unsafe interpolation in values is blocked during `${...}` and `$VAR` expansion.

Examples:

```yaml
services:
  app:
    environment:
      - "APP_ENV=prod"
      - "_DEBUG=true"         # ok
      # entrypoint override examples
    entrypoint: "bash -lc"
    command: ["./start.sh"]
  worker:
    entrypoint: ''             # clears image entrypoint
```

## Compatibility and Limitations

- YAML anchors and merge keys are disabled by default for hardening. You can enable them with `--allow-anchors` on compose commands.
- Health gating: `depends_on` supports `service_started`, `service_healthy`, and best‑effort `service_completed_successfully`.
- Recreation flags: `--force-recreate` and `--no-recreate` respected; config hash drives default reuse behavior.
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
