# System and network failures

Use this reference for host eligibility, installation, launchd or XPC failures, system startup,
guest egress, external DNS, and container-name resolution.

## Host and CLI

Check the host before interpreting a service error:

```bash
sw_vers
uname -m
command -v container
container --version
```

`container` requires Apple silicon (`arm64`) and macOS 26 or newer. If the CLI is missing, follow
the repository's [installation instructions](../../../README.md#initial-install). Do not infer host
support from a successful package installation.

If an unrecognized subcommand reports that plugins are unavailable, verify the spelling with
`container --help` and `container <group> --help` before diagnosing launchd. The base
[`container` skill](../../container/SKILL.md) documents this misleading fallback.

## System service and XPC

Start with read-only evidence:

```bash
container system status
container system version
container system logs --last 10m
launchctl managername
```

`container system status` distinguishes a healthy API server from one that is stopped, not
registered with launchd, or registered but unresponsive. `launchctl managername` records the
session type, which matters when the command runs through SSH or continuous integration instead
of a logged-in macOS GUI session.

If the user wants a repair and no workload depends on the stopped service, start it with:

```bash
container --debug system start
container system status
```

For an unhealthy registered service, collect logs before considering a stop/start cycle. A
restart is evidence only when the same command succeeds afterward; it does not explain why the
service failed. Do not repeatedly restart a service that fails the same way.

The first start can require a kernel download. Run an interactive start when approval or input is
needed. Do not pipe acceptance into the prompt or install a custom kernel without user approval.

## Separate image access from guest egress

An image pull and a process inside a running container use different network paths. A successful
pull does not prove guest networking works. With system services healthy, use the collector's
opt-in smoke test or run an equivalent disposable probe:

```bash
container run --rm docker.io/library/alpine:latest sh -lc '
  ip route
  cat /etc/resolv.conf
  ping -c 1 -W 3 1.1.1.1 || true
  nslookup github.com
  wget -q -T 10 -O /dev/null https://github.com
'
```

Interpret the probes in order:

- No interface or default route: inspect `container network list`, `container network inspect
  default`, and the container's `status.networks` from `container inspect`.
- Route present but both the raw-IP and name-based probes fail: compare the host route table with
  the container subnet. A VPN or network filter is a hypothesis only when routes overlap or the
  failure changes when the user disables it.
- The raw-IP probe works but `nslookup` fails: inspect `/etc/resolv.conf`, host DNS changes, and
  `container system logs`. Do not change application configuration yet.
- `nslookup` succeeds but HTTPS fails: preserve the TLS, proxy, or HTTP error before changing DNS.
- `nslookup` succeeds but one package mirror fails: preserve the mirror URL and TLS or HTTP error.
  Do not classify a mirror, certificate, proxy, or architecture problem as general DNS failure.

A failed raw-IP probe based on ICMP ping does not prove loss of egress; networks can filter ICMP
while HTTPS works. Use it as supporting evidence, not the deciding check.

## Container-name resolution

Test external DNS and container-name DNS separately. If external names resolve but a peer
container name does not, confirm:

1. Both containers' network attachments with `container inspect <name>`.
2. The configured domain with `container system property list`.
3. The fully qualified name, such as `db.test`, rather than bare `db`.
4. Whether the lookup originates on macOS or in another container.

Name resolution on the `default` network requires the domain configuration described in
[Networking](../../../docs/networking.md#set-up-dns-based-container-names). macOS-originated lookups
also require the privileged resolver setup. Bare-name discovery on custom networks is not the
same feature; check the current limitation linked from the base `container` skill before proposing
a DNS rewrite.

Do not create or delete `/etc/resolver` entries, restart macOS DNS, change a VPN, or replace the
default subnet merely to see whether the problem goes away. First show which lookup or route is
wrong, then explain the impact of the proposed system change.
