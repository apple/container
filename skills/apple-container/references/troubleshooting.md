# Apple Container Troubleshooting

## Quick Diagnostic Order

1. Host compatibility:
   ```bash
   sw_vers
   uname -m
   ```
2. CLI and service:
   ```bash
   command -v container
   container --version
   container system status
   ```
3. Start/restart services:
   ```bash
   container system stop
   container system start
   ```
4. Network smoke test:
   ```bash
   container run --rm docker.io/library/alpine:latest sh -lc 'cat /etc/resolv.conf; ping -c 1 -W 3 1.1.1.1; nslookup github.com'
   ```
5. Logs:
   ```bash
   container system logs --last 200
   container network inspect default
   ```

## CLI Missing Or Unsupported Host

Symptoms:

- `container: command not found`
- install docs do not match host
- service cannot start on Intel or older macOS

Checks:

```bash
uname -m
sw_vers -productVersion
```

Use Apple silicon (`arm64`) and macOS 26 or newer. If missing, install the latest signed package from Apple's GitHub releases. Ask before running privileged installer commands.

## First Start Asks For Kernel

On first `container system start`, the CLI may ask to install the recommended default kernel. Accept it for normal use. If automation fails because the prompt is non-interactive, rerun interactively or pipe a yes only when the user has consented:

```bash
printf 'Y\n' | container system start
```

## Containers Pull But DNS Or Ping Fails

Symptoms:

- image pull succeeds
- `nslookup` inside the running container times out
- `ping 1.1.1.1` inside the container fails
- `/etc/resolv.conf` points at a vmnet gateway such as `192.168.64.1`

Likely causes:

- VPN route collision with `192.168.64.0/24`
- endpoint security, firewall, or packet filter intercepting vmnet NAT
- custom network subnet still routed through a VPN interface

Checks:

```bash
netstat -rn -f inet | grep '192.168.64\|default\|utun'
container network inspect default
container run --rm docker.io/library/alpine:latest sh -lc 'ip route; cat /etc/resolv.conf; nslookup github.com'
```

Fixes:

- Ask the user to temporarily disable VPN/security network filters and retry.
- Restart services after network changes:
  ```bash
  container system stop
  container system start
  ```
- If the default subnet collides, try a custom network:
  ```bash
  container network create --subnet 192.168.105.0/24 devnet
  container run --rm --network devnet docker.io/library/alpine:latest sh -lc 'nslookup github.com'
  ```
- If both default and custom networks fail, do not keep changing app code; gather system logs.

## `apt-get update` Or Package Manager Hangs

First check raw container networking. If DNS fails, fix network/VPN first. If DNS works but one mirror hangs, switch mirrors or retry. For Ubuntu on Apple silicon, package URLs normally use `ports.ubuntu.com`.

## BuildKit Or `container build` Fails

Checks:

```bash
container builder status
container builder stop
container builder start
container build --progress plain -t local/test .
```

Common fixes:

- Use `--progress plain` to capture logs.
- Increase builder resources with `--cpus` and `--memory`.
- Use `--no-cache` for cache corruption or stale layer suspicion.
- Check network from a running container if package downloads fail during build.
- Stop/delete the builder if it is wedged:
  ```bash
  container builder stop
  container builder delete
  ```
- If every build needs more resources, set persistent builder defaults in `~/.config/container/config.toml`:
  ```toml
  [build]
  cpus = 4
  memory = "8gb"
  ```

## Port Publishing Does Not Work

Checks:

```bash
container list
container inspect <container>
container logs <container>
lsof -nP -iTCP:<host-port> -sTCP:LISTEN
```

Fixes:

- Confirm the app listens on `0.0.0.0` inside the container, not only `127.0.0.1`.
- Confirm the `-p host:container` mapping uses the application port.
- Avoid reusing a host port that is already bound.

## Bind Mount Issues

Use absolute paths or `$PWD`:

```bash
container run --rm -v "$PWD:/work" -w /work alpine:latest ls -la
```

If files appear read-only, check mount syntax, host permissions, and whether the path is under a macOS-protected location. Do not broaden the mount to the whole home directory unless the user asks.

## Machine Mode Fails

Symptoms:

- `failed to boot container machine`
- `cannot exec: container is not running`
- `/sbin/init: not found`
- `/sbin/openrc: No such file or directory`

Cause:

`container machine` expects a machine-like image that can keep running under `/sbin/init`. Plain minimal distro images may exit immediately.

Fixes:

- Use an image known to support machine mode.
- Inspect logs:
  ```bash
  container machine logs <name>
  container machine inspect <name>
  ```
- Delete broken experimental machines only after confirming they are not user data:
  ```bash
  container machine stop <name>
  container machine delete <name>
  ```

## Useful Log Commands

```bash
container system logs --last 200
container logs --boot <container>
container logs -f <container>
container machine logs <machine>
```
