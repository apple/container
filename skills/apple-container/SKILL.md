---
name: apple-container
description: Use Apple's `container` CLI for Linux container development on Apple silicon Macs. Trigger when users ask to run Linux commands on macOS, replace Docker Desktop with Apple Container, build or run OCI images, manage Apple container services, volumes, networks, registry auth, port forwarding, container machines, or debug Apple Container networking/service failures.
metadata:
  author: apple
  version: "1.0.0"
---

# Apple Container

Operate Apple's `container` CLI as a native macOS Linux container runtime for development, build, test, and debugging workflows.

## First Moves

1. Confirm the host is eligible before assuming `container` can run:
   ```bash
   sw_vers
   uname -m
   command -v container
   container --version
   ```
   Require Apple silicon (`arm64`) and macOS 26 or newer.
2. If `container` exists, start or verify the service:
   ```bash
   container system status || container system start
   ```
3. Run a smoke test before using it for real work:
   ```bash
   container run --rm docker.io/library/alpine:latest sh -lc 'uname -a; nslookup github.com'
   ```
4. For project work, mount the current directory and set `/work`:
   ```bash
   container run --rm -it -v "$PWD:/work" -w /work docker.io/library/ubuntu:24.04 bash
   ```

## When To Prefer Apple Container

- Use it when the user is on an Apple silicon Mac and needs Linux tooling that is missing or awkward on macOS.
- Use it for disposable Linux commands, building OCI images, testing Dockerfiles/Containerfiles, running services with port forwarding, or reproducing Linux-only failures.
- Prefer standard OCI images from registries (`docker.io/library/ubuntu:24.04`, `alpine:latest`, project images) and ordinary `container run` workflows first.
- Use `container machine` only when the user needs a persistent Linux environment. Machine images must boot like a tiny system and provide `/sbin/init`; many minimal distro images are not suitable without customization.
- Avoid assuming Docker CLI compatibility. The command is `container`, not `docker`, and some semantics differ.

`container` is the CLI/runtime project. It uses Apple's Containerization Swift package for lower-level container, image, and process management. If the user asks to build Swift software directly against those lower-level APIs, consult `apple/containerization`; otherwise stay in this CLI workflow.

## Core Workflows

### Disposable Linux shell

```bash
container run --rm -it -v "$PWD:/work" -w /work docker.io/library/ubuntu:24.04 bash
```

### One-shot Linux command

```bash
container run --rm -v "$PWD:/work" -w /work docker.io/library/alpine:latest sh -lc 'apk --version && ls -la'
```

### Build and run an image

```bash
container build -t local/my-app:dev .
container run --rm -p 8080:8080 local/my-app:dev
```

### Long-running service

```bash
container run -d --name web -p 8080:80 docker.io/library/nginx:latest
container logs -f web
container stop web
container delete web
```

### Inspect, copy, and clean up

```bash
container list --all
container inspect <container>
container cp ./file.txt <container>:/tmp/file.txt
container stats --no-stream
container prune
container image prune
container system df
```

## References

- Read [references/commands.md](references/commands.md) for command groups and feature coverage.
- Read [references/workflows.md](references/workflows.md) for common dev, build, network, volume, registry, and machine patterns.
- Read [references/troubleshooting.md](references/troubleshooting.md) when install, service, DNS, VPN, vmnet, kernel, builder, or machine mode fails.

## Diagnostic Script

Run the bundled diagnostic when the environment is unknown or networking behaves strangely:

```bash
bash skills/apple-container/scripts/diagnose.sh
```

From an installed skill path, use the equivalent path under that agent's skills directory.

## Safety Notes

- Ask before installing, upgrading, uninstalling, or running commands that require administrator privileges.
- Do not delete containers, images, volumes, or machines unless they were created for the current task or the user explicitly asks for cleanup.
- Stop services gracefully with `container stop` before using `container kill`.
- Treat host bind mounts as real host filesystem access. Mount only the project directory unless the user requests a wider mount.
- If a VPN is active, suspect route collisions or network filtering before changing container configuration.
