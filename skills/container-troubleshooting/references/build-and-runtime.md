# Build and runtime failures

Use this reference after `container system status` is healthy and the failure is in an image,
build, process, port, mount, or container machine.

## Image pull and platform

Preserve the full image reference and error. Separate these cases before changing registry state:

- authentication or authorization from manifest lookup and blob download failures;
- a missing tag from an unsupported image platform;
- registry TLS or proxy errors from guest DNS errors;
- an explicit `--platform` or `--arch` from the CLI default.

Use `container image inspect <image>` after a successful pull to confirm the available variant.
Do not log out, delete credentials, or replace a tag until the failing registry operation is known.

## Image build

Capture plain progress and inspect the builder:

```bash
container build --progress plain -t <image-tag> .
container builder status
container system logs --last 10m
```

Use the user's real tag in the reproduction when the tag affects later steps. Otherwise choose a
new local tag so the diagnostic build does not replace an existing image reference.

Classify the first failing build operation:

- context transfer or `COPY`: inspect the context directory, Dockerfile path, `.dockerignore`,
  and source path spelling;
- image resolve or download: reproduce the exact `FROM` image with `container image pull`;
- package download: compare with a disposable runtime network probe;
- process exit: preserve the command, exit code, and the preceding build output;
- resource exhaustion: record the builder status and requested `--cpus` or `--memory` before
  changing either value.

Do not begin with `--no-cache`: it discards evidence about whether the failure is cache-specific
and can make the retry expensive. Do not stop or delete the builder before collecting its status
and system logs. Builder deletion also removes state that can help reproduce the failure.

## Container process and boot

Use each evidence source for its own layer:

```bash
container list --all
container inspect <container>
container logs -n 200 <container>
container logs --boot -n 200 <container>
```

- Process logs show stdout and stderr from the container command.
- Boot logs show the per-container Linux VM and init path.
- Inspect output shows configured resources, mounts, published ports, networks, and runtime state.
- System logs show the macOS API, image, network, and runtime services.

If the process exits successfully but too early, inspect its entrypoint and arguments. If it exits
nonzero, reproduce the process inside the same image before changing VM or network settings. If
boot fails before the process starts, prioritize boot and system logs.

## Published ports

Check all three endpoints:

```bash
container inspect <container>
container exec <container> sh -lc 'ss -lntup 2>/dev/null || netstat -lntup'
lsof -nP -iTCP:<host-port> -sTCP:LISTEN
curl -v http://127.0.0.1:<host-port>/
```

Confirm that the process listens on the container port and on a non-loopback guest address, that
the published host and container ports match the inspect output, and that another host process
does not own the port. A successful container IP request with a failed localhost request narrows
the problem to publishing; a failed request at both paths usually does not.

## Mounts and volumes

Inspect the configured mount before broadening permissions:

```bash
container inspect <container>
ls -ld <host-source>
```

For a bind mount, confirm the expanded absolute host path, target path, read-only setting, and host
permissions. For a named volume, inspect it with `container volume inspect <volume>`. Do not mount
the whole home directory to bypass a path error. Do not delete or prune a volume during diagnosis;
volume contents are persistent and deletion is not recoverable.

Use the repository's [mount and volume guide](../../../docs/volumes.md) for current syntax and
lifecycle behavior.

## Container machines

Collect machine-specific state instead of treating a container machine as an ordinary container:

```bash
container machine list
container machine inspect <machine>
container machine logs -n 200 <machine>
container machine logs --boot -n 200 <machine>
```

Check image architecture, configured kernel, CPU and memory, home-mount mode, and whether first-boot
user provisioning completed. For custom images, confirm `/sbin/init` and the requirements in the
[container machine guide](../../../docs/container-machine.md). Do not delete and recreate a machine
as a diagnostic shortcut; deletion removes its persistent storage.
