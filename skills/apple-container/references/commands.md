# Apple Container Commands

Use this as a compact command map. Prefer `container <subcommand> --help` for exact flags on the installed version.

## System

- `container system start`: start API server, image service, networking helpers, machine API server, and first-run kernel setup.
- `container system stop`: stop containers and system services.
- `container system status`: show running state, app root, install root, and API server version.
- `container system version`: show component versions.
- `container system logs`: inspect service logs; use this for API server, vmnet, builder, and machine failures.
- `container system df`: show disk usage for images, containers, and volumes.
- `container system dns create|delete|list`: manage local DNS domains.
- `container system kernel set`: set the default kernel.
- `container system property list`: inspect system properties when supported by the installed release.

System defaults live in `~/.config/container/config.toml`. Top-level sections include `[build]`, `[container]`, `[dns]`, `[kernel]`, `[network]`, `[registry]`, `[vminit]`, and `[plugin.<id>]`. Use config for persistent defaults; use CLI flags for task-local overrides.

## Run And Build

- `container run <image> [args...]`: create and run a container, pulling the image if needed.
- `container build [context]`: build an OCI image from a Dockerfile or Containerfile using BuildKit.
- `container builder start|status|stop|delete`: manage the builder container used for image builds.

Important `run` flags:

- `--rm`: remove the container after exit.
- `-it`: interactive terminal.
- `-v "$PWD:/work" -w /work`: mount and enter the current project.
- `-p 8080:80`: publish a container port on localhost.
- `--mount type=bind,source=...,target=...,readonly`: explicit bind mount syntax.
- `--cpus 4 --memory 8G`: resource limits.
- `--platform linux/arm64` or `--platform linux/amd64`: choose image platform.
- `--rosetta`: enable Rosetta for compatible amd64 workloads.
- `--ssh`: forward the host SSH agent.
- `--init`: run an init process that forwards signals and reaps processes.
- `--init-image <image>` and `--kernel <path>`: advanced boot customization.
- `--network <name>[,mac=...][,mtu=...]`: attach a network.
- `--dns`, `--dns-search`, `--no-dns`: override DNS behavior.
- `--cap-add`, `--cap-drop`, `--read-only`, `--tmpfs`, `--shm-size`, `--ulimit`: runtime isolation and process settings.
- `--virtualization`: expose virtualization capabilities to the container when host and guest support it.

Important `build` flags:

- `-t, --tag <name>`: tag output image; may be repeated.
- `-f, --file <path>`: choose Dockerfile/Containerfile.
- `--target <stage>`: build a named stage.
- `--build-arg key=value`: pass build args.
- `--secret id=...,env=...` or `--secret id=...,src=...`: pass build secrets.
- `--platform os/arch[/variant]`: build for a platform.
- `--pull`, `--no-cache`: control freshness and cache use.
- `--cpus`, `--memory`: resource limits for the builder.
- `--output type=oci|tar|local[,dest=...]`: choose output.

## Container Lifecycle

- `container create`: create without starting.
- `container start [-a] [-i] <id>`: start a stopped container.
- `container exec [-it] <id> <cmd...>`: run a command in a running container.
- `container stop [--all] [--signal SIGTERM] [--time 5] <id...>`: graceful stop.
- `container kill [--all] [--signal KILL] <id...>`: immediate signal.
- `container delete|rm [--all] [--force] <id...>`: remove containers.
- `container list|ls [--all] [--format json|yaml|toml|table]`: list containers.
- `container inspect <id...>`: inspect containers.
- `container logs [--boot] [--follow] [-n N] <id>`: show stdio or boot logs.
- `container stats [--no-stream] [--format json|yaml|toml|table] [id...]`: resource usage.
- `container copy|cp <src> <dest>`: copy between host and running container using `id:/path`.
- `container export [-o file.tar] <stopped-id>`: export a stopped container filesystem.
- `container prune`: delete stopped containers.

## Images

- `container image pull <ref>`: pull from a registry.
- `container image list|ls [-v] [--format json|yaml|toml|table]`: list local images.
- `container image inspect <ref...>`: inspect images.
- `container image tag <source> <target>`: create another reference.
- `container image push <ref>`: push to a registry.
- `container image save -o image.tar <ref...>`: save image archive.
- `container image load -i image.tar`: load image archive.
- `container image delete|rm [--all] [--force] <ref...>`: remove images.
- `container image prune [-a]`: remove unused images.

## Registry

- `container registry login <server>`: authenticate to a registry.
- `container registry logout <server>`: remove auth.
- `container registry list|ls`: list registry logins.

`--scheme auto` treats loopback, RFC1918 private IPs, and container DNS-domain hosts as internal/local and uses HTTP; otherwise it uses HTTPS.

## Network

- `container network create [--subnet CIDR] [--subnet-v6 CIDR] [--internal] <name>`: create a NAT or host-only network.
- `container network list|ls`: list networks.
- `container network inspect <name>`: inspect subnet, gateway, and mode.
- `container network delete|rm <name...>`: remove networks.
- `container network prune`: remove unused networks.

The built-in `default` network is NAT-backed by vmnet. On macOS, VPNs and network filters can interfere with the VM bridge or route table.

## Volumes

- `container volume create <name>`: create a managed volume.
- `container volume list|ls`: list volumes.
- `container volume inspect <name>`: inspect details.
- `container volume delete|rm <name...>`: delete volumes.
- `container volume prune`: remove unused volumes.

Use bind mounts for direct project access; use volumes for runtime data that should not live in the project tree.

## Machines

- `container machine create <image> --name <name> [--set-default] [--cpus N] [--memory 8G] [--home-mount rw|ro|none]`: create and boot a persistent Linux machine.
- `container machine run [-n name] -- <cmd...>`: run a command or shell, booting the machine if needed.
- `container machine set -n <name> cpus=4 memory=8G home-mount=ro`: change configuration; restart to apply.
- `container machine list|ls`, `inspect`, `logs`, `stop`, `delete`, `set-default`: manage machines.

Machine images need a suitable `/sbin/init`. If a plain distro image exits with `/sbin/init: not found` or similar, use a machine-oriented image or build a custom image with a minimal init.
