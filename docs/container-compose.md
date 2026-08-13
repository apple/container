# Container Compose

`container compose` runs the Docker Compose CLI inside a persistent Linux
container machine. It provides a Docker-compatible Compose workflow while
keeping the Docker daemon, images, containers, networks, and volumes inside an
isolated machine managed by `container`.

## Overview

The Compose plugin runs the real `/usr/bin/docker compose` command inside one
persistent machine named `compose`. It does not parse Compose files or
translate Compose requests into Apple Container API calls.

All Compose projects share this machine and its nested Docker daemon:

```text
compose machine
└── Docker Engine
    ├── Compose project A
    ├── Compose project B
    └── Compose project C
```

Compose project isolation follows Docker Compose's normal project-name rules.
Use `-p`, `COMPOSE_PROJECT_NAME`, or a top-level `name` when projects need
stable, distinct names. Dedicated Compose machines per namespace are a deferred
future enhancement.

The machine uses a read-write, same-path home mount. A working directory below
macOS `$HOME` is visible at the same path inside the machine, so Compose files
and bind mounts under the home directory do not need to be copied. Bind sources
outside the mounted home are unsupported.

The machine's Docker data persists across stop and boot. `container compose
down` removes only the selected Compose project's resources; it does not stop
or delete the machine.

## Quickstart

Start the container system if it is not already running:

```bash
container system start
```

The first Compose command automatically builds the bundled Compose machine
image locally when the default image is not already in the host image store.
This may take a few minutes on first use. From a directory under `$HOME`
containing `compose.yaml` or `docker-compose.yml`, run the normal Compose
commands:

```bash
container compose up -d
container compose ps
container compose logs -f
container compose down
```

The first normal invocation creates or boots the persistent `compose` machine,
waits for Docker Engine, and forwards the Compose arguments unchanged. Later
invocations reuse the same machine.

### Accessing services

The Compose machine address is reported when the machine becomes ready. If the
`machine` DNS domain is installed, the machine is also available as
`compose.machine`:

```bash
sudo container system dns create machine
```

Published service ports are exposed through the machine's address. Nested
Compose ports are not automatically published on macOS's loopback interface.
One-label project aliases such as `nixstasis.compose.machine` resolve to the
same machine address when the `machine` DNS domain is configured; the Compose
stack must provide the matching host-based ingress.

### Using Docker-compatible clients

The plugin can expose the nested Docker daemon through a per-user Unix socket.
`--socket-path` only prints the endpoint; it does not start the machine. On first
use, run a normal Compose command to create and boot the machine before requesting
the endpoint:

```bash
container compose version
export DOCKER_HOST="$(container compose --socket-path)"
docker version
docker ps
```

If the machine was stopped, start it before using the exported endpoint:

```bash
container machine start compose
DOCKER_HOST="$(container compose --socket-path)" docker ps
```

The endpoint is mode `0600` and grants Docker-root-equivalent access to the
Compose machine. Do not make it group- or world-writable.

### Managing the machine

The Compose machine is an ordinary persistent container machine with a Compose
ownership marker. Its boot resources can be changed with `container machine set`:

```bash
container machine set -n compose cpus=8 memory=8gb
container machine stop compose
container compose ps
```

Resource changes take effect on the next boot and affect every Compose project
using the machine. To release resources while retaining Docker data, stop it:

```bash
container machine stop compose
```

To remove the machine and its persistent Docker data:

```bash
container machine delete compose
```

Machine deletion is destructive and removes all Compose projects, images,
volumes, networks, and build cache stored in that machine.

Idle shutdown is disabled by default. Configure `idle-shutdown-seconds` in
`[plugin.compose]` to a positive number of seconds. Active Docker client
operations, including builds, pulls, and pushes, reset the idle timer.

## Differences from Docker Desktop's compose

`container compose` is closer to running Docker using [Lima](https://github.com/lima-vm/lima)
than to Docker Desktop's integrated Compose experience. In both approaches,
Docker runs inside a Linux virtual machine and the host CLI talks to that
Docker daemon. `container` uses its own persistent container machine and the
nested Docker Engine image supplied by the Compose plugin.

### Docker daemon location

Docker Desktop manages a Linux VM and Docker installation as part of its desktop
application. With `container compose`, Docker Engine runs inside the persistent
`compose` machine. The machine is controlled with `container machine` commands
and remains independent of Docker Desktop.

### Resource and lifecycle management

Docker Desktop commonly manages one application-level VM and its lifecycle.
Here, the Compose machine is explicit and persistent:

```bash
container machine inspect compose
container machine set -n compose cpus=8 memory=8gb
container machine stop compose
container machine delete compose
```

`container compose down` does not stop the machine. Multiple Compose projects
share the machine unless a future namespace feature is added.

### Filesystem and bind mounts

The host home directory is mounted at the same path inside the machine. Compose
working directories and bind sources must be below `$HOME`; arbitrary paths
outside that mount are not available. This is similar to VM-based Docker
workflows such as Lima, rather than a daemon running directly on macOS.

### Networking and published ports

Compose services run inside the nested Docker daemon and its Linux networking
stack. Published ports are reachable through the Compose machine's IP address,
not automatically through `localhost` on macOS. Use the machine DNS name when
configured, or inspect the startup diagnostics for the address.

### Images and build cache

The Compose machine has its own Docker image store and BuildKit cache. Images
built or pulled by `container` itself, Apple Container images, Kubernetes
containerd images, and Compose Docker images are separate stores. Transfers
between stores must be explicit.

### Docker socket access

The optional socket returned by `container compose --socket-path` connects to
the nested Docker daemon. It is not Docker Desktop's socket and it does not
share Docker Desktop's containers, images, networks, or volumes.

### Machine image and updates

The bundled Compose machine image contains Docker Engine, BuildKit, Buildx, and
the Compose plugin. When the default `container-compose-machine:local` image
is absent, `container compose` builds it from the Containerfile shipped with
the installed plugin and stores it in the host `container` image store before
creating the machine.

Updating the host `container` executable does not implicitly migrate or replace
an existing Compose machine image.

### Custom machine images (testing only)

Normal use requires no image configuration. `container compose` uses the
bundled `container-compose-machine:local` image and builds it automatically if
it is missing.

To test a replacement image when creating a new Compose machine, set:

```bash
CONTAINER_COMPOSE_MACHINE_IMAGE=my-compose-machine:dev container compose ps
```

This variable overrides the bundled image; it does not rebuild the bundled
image. It also does not replace an existing `compose` machine. Remove the
variable to return to the normal bundled-image workflow.

### Configure the Compose machine

Normal use needs no image setting. To configure the persistent Compose machine,
edit the user configuration file at `~/.config/container/config.toml`:

```toml
[plugin.compose]
cpus = 4
memory = "4gb"
idle-shutdown-seconds = 600
```

- `cpus` sets the number of virtual CPUs. The default is `4`.
- `memory` sets the machine's RAM. The default is `"4gb"`. Values use binary
  units such as `"2gb"`, `"8gb"`, or `"4096mb"`; see the
  [`MemorySize` format](./container-system-config.md#memorysize-format).
- `idle-shutdown-seconds` optionally powers off the machine after that many
  seconds with no running Docker containers. `0` disables idle shutdown.

Restart the container service after editing this file so it reloads the
configuration:

```bash
container system stop
container system start
```

These settings apply to the shared `compose` machine and therefore affect every
Compose project. CPU and memory settings are used when the machine is created;
the idle-shutdown setting is applied on the next Compose invocation. To resize
an existing machine, use `container machine set`:

```bash
container machine set -n compose cpus=8 memory=8gb
container machine stop compose
container compose ps
```

## See also

- [`container compose` command reference](./command-reference.md#container-compose)
- [`Container machine`](./container-machine.md)
- [Compose configuration reference](./container-system-config.md#plugincompose)
- [Lima](https://github.com/lima-vm/lima)
