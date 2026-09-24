# container-compose

`container-compose` is a Python script that provides a `docker-compose`-compatible interface for Apple's `container` CLI. It reads a standard `docker-compose.yml` file and translates each subcommand into the equivalent `container` invocations, so you can bring up multi-container applications without rewriting your existing compose files.

## Why container-compose

The `container` CLI operates on individual containers. Many projects describe their services in a `docker-compose.yml` that coordinates several containers, their networks, and their volumes. `container-compose` bridges that gap: it parses the compose file, creates the required networks and volumes, respects `depends_on` ordering, and runs each service as a labelled `container run` invocation so they can later be queried and torn down as a group.

## Prerequisites

- Apple `container` installed and the system service started (`container system start`)
- Python 3.11 or later
- PyYAML: `pip3 install pyyaml --break-system-packages`

## Install

Copy the script to a directory on your `PATH`:

```bash
cp examples/compose-example/container-compose /usr/local/bin/container-compose
chmod +x /usr/local/bin/container-compose
```

## Quickstart

```bash
# Start all services defined in docker-compose.yml (detached by default)
container-compose up

# Check running services
container-compose ps

# Stream logs from all services
container-compose logs -f

# Stop and remove containers and networks
container-compose down
```

## Supported subcommands

| Subcommand | Description |
|------------|-------------|
| `up [-d] [--build] [service…]` | Create networks and volumes, then start services in dependency order |
| `down [-v]` | Stop and delete containers and networks; `-v` also removes named volumes |
| `ps` | List containers for the current project |
| `logs [-f] [--tail N] [service…]` | Print (or follow) container output |
| `exec <service> <cmd…>` | Run a command in a running service container |
| `build [--no-cache] [service…]` | Build images from `build:` definitions |
| `pull [service…]` | Pull service images |
| `start / stop / restart [service…]` | Start, stop, or restart existing containers |
| `rm [-f] [-s] [service…]` | Remove stopped containers; `-s` stops them first |
| `run [--rm] <service> [cmd…]` | Run a one-off command on a service |
| `config` | Print the parsed compose configuration |

## Supported compose keys

The following keys are translated to `container run` flags:

- `image`, `build` (context, dockerfile, args)
- `command`, `entrypoint`
- `environment`, `env_file`
- `ports`, `volumes` (bind mounts and named volumes), `tmpfs`
- `networks` (first network only — see limitations below)
- `depends_on` (list and `condition` dict form)
- `labels`, `container_name`
- `mem_limit`, `cpus`, `deploy.resources.limits`
- `cap_add`, `cap_drop`
- `working_dir`, `user`
- `tty`, `stdin_open`
- `dns`, `dns_search`
- `read_only`, `init`
- `shm_size`

## Project isolation

Every resource (container, network, volume) is tagged with the project name, which defaults to the current directory name. Override it with `-p` or the `COMPOSE_PROJECT_NAME` environment variable:

```bash
container-compose -p staging up
```

All `container-compose` commands scope their queries to the project label, so multiple projects can coexist on the same host.

## Known limitations

The following `docker-compose` features are not yet supported by the `container` CLI and are silently ignored or warned about:

| Feature | Notes |
|---------|-------|
| Multiple networks per service | `container` does not support `network connect` after run; only the first declared network is attached |
| `extra_hosts: host-gateway` | Docker-specific alias; use an explicit IP instead |
| `restart` policies | `container run` has no `--restart` flag yet |
| `healthcheck` | Not surfaced on `container inspect` output |
| Swarm / deploy keys beyond `resources.limits` | Ignored |

See [examples/compose-example](../examples/compose-example/) for a working walkthrough.
