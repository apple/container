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
   Require Apple silicon (`arm64`) and macOS 26 (Tahoe) or newer. The runtime relies on
   macOS 26 virtualization and networking APIs; older macOS is not supported for real use.
2. If `container` is not installed, install it (see [Install](#install)). Ask before running
   privileged steps, since the installer writes under `/usr/local` and needs an admin password.
3. Once `container` exists, start or verify the service:
   ```bash
   container system status || container system start
   ```
4. Run a smoke test before using it for real work:
   ```bash
   container run --rm docker.io/library/alpine:latest sh -lc 'uname -a; nslookup github.com'
   ```
5. For project work, mount the current directory and set `/work`:
   ```bash
   container run --rm -it -v "$PWD:/work" -w /work docker.io/library/ubuntu:24.04 bash
   ```

## Install

Use Homebrew when available; it is the least error-prone path and keeps `container` upgradable
with the user's other tooling:

```bash
brew install container
```

If Homebrew is not installed, use Apple's signed installer rather than installing Homebrew just for
this. The official steps:

1. Download the latest signed installer package for `container` from the
   [GitHub release page](https://github.com/apple/container/releases).
2. Double-click the package file and follow the instructions.
3. Enter the administrator password when prompted, so the installer can place files under
   `/usr/local`.

When driving this from the terminal without a GUI, run the same package non-interactively (ask the
user before the privileged step):

```bash
# After downloading container-<version>-installer-signed.pkg to the current directory:
sudo installer -pkg ./container-*-installer-signed.pkg -target /
```

The installer places files under `/usr/local` and bundles helper scripts:

```bash
/usr/local/bin/update-container.sh           # upgrade in place
/usr/local/bin/update-container.sh -v 0.3.0  # pin a specific version (downgrade)
/usr/local/bin/uninstall-container.sh -k     # uninstall, keep user data
/usr/local/bin/uninstall-container.sh -d     # uninstall, delete all data
```

After installing, initialize and verify the runtime:

```bash
container system start    # first run may prompt to install the recommended kernel; accept it
container system status
container --version
```

Note: `brew install container` succeeds on macOS 15 (Sequoia), but the runtime is only supported
on macOS 26 (Tahoe) or newer — a clean install does not by itself prove the host can run
containers. Always confirm the macOS version from step 1 before relying on it.

Docs: [installation & user guide](https://apple.github.io/container/documentation/) ·
[Homebrew formula](https://formulae.brew.sh/formula/container) ·
[GitHub project](https://github.com/apple/container)

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
