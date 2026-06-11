# Apple Container Workflows

## Install Or Upgrade

1. Verify the host:
   ```bash
   sw_vers
   uname -m
   ```
2. Use the latest signed installer from Apple Container releases.
3. Start services:
   ```bash
   container system start
   container system status
   ```
4. Upgrade with:
   ```bash
   container system stop
   /usr/local/bin/update-container.sh
   container system start
   ```

Installation, upgrade, downgrade, and uninstall may require administrator privileges. Ask the user before running privileged commands.

## Replace A Docker-Style Dev Shell

```bash
container run --rm -it \
  -v "$PWD:/work" \
  -w /work \
  docker.io/library/ubuntu:24.04 \
  bash
```

Then install temporary tools inside the disposable shell:

```bash
apt-get update
apt-get install -y build-essential git curl python3 python3-pip
```

For repeated use, create a project Dockerfile and build a local image:

```Dockerfile
FROM docker.io/library/ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
CMD ["bash"]
```

```bash
container build -t local/project-dev:latest .
container run --rm -it -v "$PWD:/work" -w /work local/project-dev:latest
```

## Run A Web Service

```bash
container run -d --name app -p 3000:3000 -v "$PWD:/work" -w /work local/app:dev
container logs -f app
curl http://localhost:3000
container stop app
container delete app
```

Use `container inspect app` when port publishing or IP allocation is unclear.

## Access Host Services From A Container

Try the container network gateway as the host-side address:

```bash
container network inspect default
container run --rm docker.io/library/alpine:latest sh -lc 'ip route; nc -vz 192.168.64.1 5432'
```

If the host service binds only to `127.0.0.1`, configure it to listen on the appropriate host interface or use a published socket/workflow supported by the service.

## Use Host SSH Credentials

```bash
container run --rm -it --ssh -v "$PWD:/work" -w /work docker.io/library/ubuntu:24.04 bash
```

Prefer `--ssh` over copying private keys into containers.

## Use Volumes

```bash
container volume create node-cache
container run --rm -it \
  -v "$PWD:/work" \
  --mount type=volume,source=node-cache,target=/root/.npm \
  -w /work \
  local/project-dev:latest
```

Use `container volume inspect`, `container volume list`, and `container volume prune` for maintenance.

## Custom Networks

Create custom networks for isolation or subnet conflicts:

```bash
container network create --subnet 192.168.105.0/24 devnet
container run --rm --network devnet docker.io/library/alpine:latest sh
container network inspect devnet
```

If traffic fails on custom and default networks, suspect host VPN, endpoint security, firewall, or macOS vmnet routing before changing application code.

To change default subnets for newly-created networks, edit `~/.config/container/config.toml`:

```toml
[network]
subnet = "192.168.100.0/24"
subnetv6 = "fd00:abcd::/64"
```

Restart services after changing system config:

```bash
container system stop
container system start
```

## Registry Auth And Image Transfer

```bash
container registry login ghcr.io
container build -t ghcr.io/OWNER/IMAGE:tag .
container image push ghcr.io/OWNER/IMAGE:tag
container image save -o image.tar ghcr.io/OWNER/IMAGE:tag
container image load -i image.tar
```

Do not put tokens directly in command arguments when an environment variable or registry login flow is available.

## Persistent Container Machines

Use machines for long-lived Linux environments:

```bash
container machine create alpine:3.22 --name devbox --set-default --cpus 4 --memory 8G --home-mount rw
container machine run -n devbox -- uname -a
container machine run -n devbox
container machine stop devbox
```

Machine caveats:

- The image must boot with a valid `/sbin/init`.
- Config changes via `container machine set` apply after restart.
- Prefer `home-mount=ro` when the task does not require writing into the user's home directory.
- Use `container machine logs <name>` when boot or exec hangs.

## Rosetta And Platforms

Apple silicon is `arm64`; prefer native arm64 images. For x86_64-only tools:

```bash
container run --rm --platform linux/amd64 --rosetta docker.io/library/ubuntu:24.04 uname -m
```

If an image has both arm64 and amd64 variants, use `--platform` only when the requested architecture matters.

To change persistent defaults, use `~/.config/container/config.toml`:

```toml
[container]
cpus = 4
memory = "4gb"

[build]
cpus = 4
memory = "8gb"
rosetta = true

[registry]
domain = "docker.io"
```

## Cleanup

After experiments:

```bash
container list --all
container prune
container image prune
container volume prune
container network prune
container system df
```

Do not prune globally in a user's active development environment without asking.
