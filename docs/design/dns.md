# DNS Design

Status: Draft

This document describes how `container` handles DNS today and records the
behavioral requirements that should hold as DNS support changes. It is intended
to be updated as related hostname, alias, forwarding, and host networking work
lands.

## Goals

- Describe the current DNS paths for host-to-container, container-to-host, and
  workload-to-upstream resolution.
- Keep DNS server configuration distinct from per-container resolver
  configuration.
- Record invariants for name normalization, conflict checks, DNS record
  generation, and forwarding behavior.
- Provide a place to evaluate container-facing DNS designs before they are
  wired into the runtime path.

## Non-Goals

- This document does not specify a full Docker Compose compatibility layer.
- This document does not require a single implementation strategy for a
  container-facing DNS listener.
- This document does not change user-facing command behavior by itself.

## Terms

- Workload: a process running inside a Linux container.
- Workload resolver configuration: the DNS configuration written into the
  container filesystem, such as `/etc/resolv.conf`.
- Host resolver configuration: macOS resolver state, including files under
  `/etc/resolver`.
- Host DNS service: the `container-apiserver` DNS listeners that answer scoped
  host queries on loopback ports.
- Hostname database: the per-network mapping from container DNS names to
  allocated network attachments.
- Container-facing resolver: a future DNS service reachable from workloads on
  an attached container network.

## Current Behavior

### Workload to Upstream Resolvers

When a container has a network attachment but no explicit DNS nameservers,
the Linux runtime configures the container DNS nameserver from the first
attachment gateway. For vmnet NAT networks, workload DNS queries go to the
NAT bridge IP, where the vmnet DNS proxy forwards them through mDNSResponder
to the host's configured upstream resolvers.

Explicit DNS settings from container configuration are separate from that
default. Flags such as `--dns`, `--dns-search`, `--dns-option`, `--dns-domain`,
and `--no-dns` control the workload resolver configuration. They do not create
or modify host-side DNS listeners.

### Host to Container Names

`container system dns create <domain>` writes a scoped macOS resolver
configuration file under `/etc/resolver` using the
`containerization.<domain>` prefix, then signals mDNSResponder to reload.
The standard scoped domain points at the host DNS service on
`127.0.0.1:2053`.

`container-apiserver` starts that host DNS service and uses
`ContainerDNSHandler` to resolve scoped container names through
`NetworksService.lookup(hostname:)`. A records come from IPv4 attachments.
AAAA records come from IPv6 attachments when present.

### Host to Localhost Names

`container system dns create <domain> --localhost <ip>` writes a scoped
resolver file that points at `127.0.0.1:1053` and records the localhost
mapping in an `options localhost:<ip>` entry. `LocalhostDNSHandler` monitors
these resolver files and answers those names with the configured IPv4 address.

The traffic path for this feature also depends on packet-filter rules managed
through `pfctl`. DNS resolution and packet redirection are separate pieces of
the feature and should report failures separately.

### Container Names and Hostname Records

Container creation maps each network attachment to a hostname. The default
network attachment hostname is derived from the configured DNS domain and the
container id. The runtime also uses the first network attachment hostname, or
the container id when no attachment hostname exists, as the Linux guest
hostname.

Before container creation succeeds, the API server checks existing containers
for conflicting attachment hostnames. The network helper also keeps an
in-memory hostname database for allocated attachments. Hostname lookup is
normalized consistently so case differences and optional trailing dots do not
create distinct records for the same DNS name.

## Behavioral Requirements

DNS-001: If a workload has no explicit DNS nameservers and has at least one
network attachment, the runtime MUST configure the workload nameserver from the
first attachment gateway.

DNS-002: Explicit workload DNS configuration MUST be preserved. Host resolver
configuration and workload resolver configuration MUST NOT silently imply each
other.

DNS-003: Hostnames used for allocation, lookup, and conflict checks MUST be
normalized consistently. Lookup MUST treat case differences and a single
trailing dot as equivalent.

DNS-004: For a known hostname with no IPv6 attachment, an AAAA query MUST
return NODATA with `noError`, not NXDOMAIN. Some resolvers treat NXDOMAIN for
AAAA as proof that the name does not exist.

DNS-005: Host-scoped container DNS MUST only answer names backed by the
hostname database for container networks.

DNS-006: Container creation MUST fail before start when the requested
attachment hostnames conflict with existing container attachment hostnames.
Future `--alias` or `--hostname` features SHOULD preserve this create-time
conflict policy.

DNS-007: A container-facing resolver, if added, MUST scope answers and
forwarding to traffic from its attached container network.

DNS-008: A container-facing resolver MUST prefer local container records before
forwarding to upstream resolvers.

DNS-009: If vmnet's DNS proxy is disabled for a network, the replacement
resolver MUST start successfully before the network is reported healthy.
Failure to bind or serve the replacement path MUST fail network startup.

DNS-010: A container-facing resolver MUST NOT rely on wildcard UDP/53 binding
as its primary design. The design needs to account for mDNSResponder, vmnet
bridge addresses, privileges, and third-party DNS, VPN, and network-security
software.

DNS-011: `host.docker.internal` or `host.container.internal` style support
MUST keep DNS record generation separate from packet-filter redirection. A DNS
success must not hide a `pfctl` failure.

## Extension Points

### Name Normalization

Hostname normalization is shared by the network attachment allocator and
network lookup path. Future DNS features should use the same normalization
rules for container names, aliases, and hostnames before doing conflict checks
or DNS lookups.

### Aliases

Aliases should add additional names for an attachment without changing the
container management id. Alias records should participate in the same
create-time conflict checks as primary attachment hostnames.

### Guest Hostname

The guest hostname currently comes from the first network attachment hostname
or container id. A distinct user-configured guest hostname is a separate
question from DNS aliases and should not be required for basic service
discovery.

### Container-Facing DNS

A container-facing resolver could allow workloads to resolve other containers
on the same network while preserving upstream DNS forwarding. A candidate
design is a per-network resolver owned by the vmnet helper, with local records
served from the network service and upstream queries forwarded to system
resolvers.

Validation so far shows that binding the resolver directly to the reported
vmnet gateway address is not sufficient:

- With vmnet DNS proxy left enabled, the signed vmnet helper started the
  network, then binding `192.168.64.1:53` failed with `EADDRNOTAVAIL`.
- With `vmnet_network_configuration_disable_dns_proxy` applied before
  `vmnet_network_create`, the signed vmnet helper still started the network,
  then binding `192.168.64.1:53` still failed with `EADDRNOTAVAIL`.

Disabling the vmnet DNS proxy alone therefore does not make the gateway address
host-bindable in this environment.

## Open Questions

- Does vmnet expose a host-bindable address or socket path for DNS service on
  the network gateway, or does this need an mDNSResponder or packet-filter
  integration?
- If packet-filter redirection is used, how should rules avoid conflicts with
  existing localhost forwarding rules and third-party network software?
- How should custom workload `--dns` settings interact with future
  container-facing DNS?
- Which names should be reserved for host access, such as
  `host.container.internal`, and where should conflicts be enforced?
- What diagnostics should be shown when mDNSResponder, `/etc/resolver`, vmnet,
  or `pfctl` state prevents DNS from working?

## Test Matrix

- Host scoped domain: create a domain, start a container, resolve its name from
  the host, then delete the domain and verify cleanup.
- Workload upstream DNS: start a container without explicit DNS nameservers and
  resolve an external domain from the workload.
- Explicit DNS configuration: verify `--dns`, `--dns-search`, `--dns-option`,
  `--dns-domain`, and `--no-dns` preserve the requested workload resolver
  configuration.
- Record behavior: verify A, AAAA, NODATA-for-missing-IPv6, and NXDOMAIN for
  unknown names.
- Conflict policy: verify duplicate container hostnames and aliases fail before
  container start.
- Container-facing resolver candidates: test vmnet proxy enabled and disabled,
  default and custom subnets, host-only and NAT networks, and third-party VPN
  or DNS software.
- Host access names: verify DNS records and packet-filter redirection failures
  are reported independently.
