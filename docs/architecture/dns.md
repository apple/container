# DNS architecture

This document describes the DNS architecture of `container`. It covers:

* The components that work together to resolve names
* The names a container can have
* The path of a query through the system
* The invariants that the implementation relies on
* The security properties of the design

For user-level instructions, see [Networking](../networking.md).

## Components

Name resolution involves four pieces.

* **Resolver files.** `container system dns create <domain>` writes `/etc/resolver/containerization.<domain>` and signals mDNSResponder. A file for a regular domain contains `nameserver 127.0.0.1` and `port 2053`, which tells macOS to send queries for names under that domain to the container DNS server. A domain created with `--localhost <address>` contains `port 1053` and an `options localhost:<address>` line, and is served by a different handler. These files are host state, and `container` does not control their contents after writing them. macOS chooses the resolver whose domain is the most specific match for a query.
* **The container DNS server.** `container-apiserver` runs a DNS server on `127.0.0.1:2053`. Each query passes through `StandardQueryValidator`, which accepts only single-question standard queries, and then through a `CompositeResolver` that tries `ContainerDNSHandler` and then `NxDomainResolver`. `ContainerDNSHandler` answers A and AAAA queries with a TTL of 5 seconds. Anything it does not answer becomes NXDOMAIN.
* **The localhost DNS server.** A second server on `127.0.0.1:1053` runs `LocalhostDNSHandler`, which answers the exact domain names of resolver files that have the localhost option, using the address in that option. It reads only those files and never consults a network helper.
* **Network helpers.** Each network is served by a helper process, such as the vmnet helper. The helper allocates addresses for attachments and is the source of truth for which names exist on its network. `NetworksService` in the API server holds a client for each helper.

Both DNS servers listen on the loopback address only, so they cannot be queried from other machines.

## Names of a container

Each network attachment of a container has a hostname. It is derived from the container ID and from the default DNS domain, which is the `domain` key in the `[dns]` table of the system configuration. The container ID is the value of `--name`from `container create` or `container run`, or a generated lowercase UUID when there is no `--name`. The `--dns-domain` option of `container create` or `container run` sets the search domain inside the container and does not change the hostname.

The hostname of the first attachment depends on which of three cases applies.

* **The container ID contains a dot.** The ID is taken to be a fully qualified name, and the hostname is the ID with a trailing dot. `--name web.example.test` gives `web.example.test.`. The default domain is not appended, even when one is configured.
* **The container ID has no dot, and a default domain is configured.** The hostname is the ID, the domain and a trailing dot. `--name foo` with the domain `test` gives `foo.test.`.
* **The container ID has no dot, and no default domain is configured.** The hostname is the bare ID, such as `foo`. It is not under any domain, so no resolver file sends queries for it to the container DNS server.

A container started without `--name` has a generated ID with no dot, so it follows the second or third case. Every later attachment gets the container ID as its hostname, with no domain added, in all three cases. Only a hostname under a registered domain can be resolved from macOS, because the resolver files forward queries by domain. That means the first attachment of a container in the first two cases is reachable by name, and an unqualified hostname, whether from the third case or from a later attachment, is not.

An attachment can also declare aliases, which are additional names that resolve to the same address. An alias is one of two forms, written as the value of the `alias` property of `--network`.

* An **exact alias** is a name, such as `api.example.test`.
* A **subtree alias** is a name with a leading dot, such as `.example.test`. It matches every name below its base, at one or more labels, and does not match the base itself. The wildcard semantics follow RFC 4592.

An alias that has no dot is qualified with the default DNS domain when the container is created, the same way a container ID without a dot becomes a hostname. `alias=api` with the domain `test` is stored as `api.test`, and `alias=.gateway` is stored as `.gateway.test`. A name with a dot is stored as it is. The qualification happens in the CLI, so the stored configuration, the API server and the helpers only ever see the qualified names, and a later change to the default domain does not alter them. Without a default domain, the name stays as it is and fails the check for a fully qualified name.

Aliases are part of the attachment configuration (`AttachmentOptions.aliases`), are stored in their normalized string form, and cannot be changed after the container is created. `DNSMatchRule` in the `DNSServer` module parses and matches them. Names are compared by label, are not case sensitive, and are compared without a trailing dot.

## Resolving a query

1. The application asks the system resolver for a name. macOS finds a resolver file whose domain matches and sends the query to `127.0.0.1:2053`.
2. The container DNS server decodes the question and `ContainerDNSHandler` calls `NetworksService.lookup` with the name.
3. `NetworksService` asks each network helper to match the name. A helper checks its own attachments in a fixed order: the hostname of an attachment, then an exact alias, then the subtree alias with the longest base. It replies with the attachment, and with how the name matched.
4. `NetworksService` takes the first reply that is a hostname or exact alias match. If there is none, it takes the subtree match with the most labels in its base, once every helper has answered.
5. The handler answers with the address of the attachment, using the queried name as the owner name of the record. When the name exists but the attachment has no IPv6 address, an AAAA query gets NODATA (no error, no records) instead of NXDOMAIN. musl libc treats NXDOMAIN for AAAA as the whole name not existing, so this is required for such names to resolve.

## Registration lifecycle

Names are registered in two places, and the order matters.

When a container is created, `ContainersService.create` validates the names of its attachments under the container creation lock, before the container is created. This is the only place that sees every container, so it is where uniqueness is enforced.

When the container starts, the runtime service opens one XPC session to the helper of each network and calls `allocate` with the hostname, the optional MAC address, and the aliases. The helper registers the hostname and aliases for the lifetime of the session. A helper that supports aliases echoes them in its reply to acknowledge them. When a container requests aliases and the reply does not acknowledge them, the client treats the plugin as unsupported and fails. A container without aliases sends no aliases and needs no acknowledgement, so a helper that predates aliases keeps working for it. When the session ends, whether the container stops, crashes or disconnects, the helper releases the address and the names. If any allocation fails during startup, the runtime service closes every session it opened, which releases the earlier allocations.

## Invariants

* **Exact names are unique.** A hostname or an exact alias is claimed by at most one attachment across all networks, whether its container is running or stopped. Creation fails if a new hostname or alias matches an existing hostname or alias, in either direction. The lookup relies on this to stop at the first hostname or exact alias match.
* **Aliases are qualified.** Every exact alias is a fully qualified name with at least two labels once the default domain has been added, because a name with a single label is never under a registered domain and could not be resolved from macOS. The API server enforces this for every client, whether or not the CLI qualified the name.
* **A subtree is owned.** The base of a subtree alias is the hostname or an exact alias of the same attachment, and has at least two labels. A container can therefore not claim the names below another container's name, and two containers cannot declare the same subtree. A subtree and its base always resolve to the same attachment.
* **Precedence is total.** An exact name beats a subtree, and a longer subtree base beats a shorter one. Two different subtrees that match a name and have the same number of base labels would have the same base, which one container owns, so there is no tie.
* **Names are canonical.** Hostnames and aliases are compared lowercase and without a trailing dot, and the helper stores them that way. A container named `Foo` is therefore found by a query for `foo`.
* **The helper is authoritative.** The addresses in answers come only from the allocation that a helper made for the attachment. No configuration value can supply an address.
* **Names live as long as the allocation.** An allocation and its aliases are released together, so a stopped container does not keep answering.
* **Existing configurations stay valid.** The alias fields in the configuration and in the helper protocol are optional. A reply without a match kind is a hostname match, and a helper that implements only the original methods keeps working.

## Security considerations

* Aliases come only from the request that creates the container, through the CLI or the API. They are never read from image metadata, labels or anything that a workload controls.
* Both DNS servers accept connections from the loopback address only.
* The create-time checks run under the creation lock, and aliases cannot change afterward, so there is no later path to re-validate. The helper also refuses an alias that is already registered on its own network, as a second line of defense.
* Matching is by label, which keeps `evilexample.test` from matching `.example.test`.
* The ownership rule and the two-label minimum keep a subtree alias from capturing a whole top-level domain or the names of other containers. Exact names always win over a subtree.
* A subtree makes every name below its base resolve to the container. A proxy behind such a name receives the requested name in the `Host` header and must treat it as untrusted input.
* Answers are a single record from an in-memory table, with no recursion, so aliases add no amplification.
* The checks do not look at the resolver files. They are host state that can change at any time, and they do not limit what the server answers, because a client can query port 2053 directly.

## Known limitations

* **Case of the answer.** `DNSName` lowercases labels when a query is decoded, so a response echoes a lowercased question and owner name even when the client used mixed case. DNS is case preserving (RFC 4343), and resolvers that randomize the case of query names (0x20 encoding) may discard a response whose case does not match. This predates aliases. Fixing it means keeping the original labels in the decoded question.
* **Domains outside the resolver files.** An alias is reachable from macOS only when the most specific registered domain that covers it is a regular one. A name under a domain created with `--localhost`, or under no registered domain, does not reach the container DNS server through the system resolver. Container creation does not warn about this.
* **Unavailable networks.** `NetworksService.lookup` calls the helpers one at a time and does not hold the networks state lock while it does, so a network being created or deleted does not delay DNS answers. A helper that is starting up, shutting down or has failed cannot answer, so its network is skipped and the failure is logged. A name that only that network could answer is reported as not found for that query. A helper that hangs, instead of failing, still delays the queries that reach it, because the calls have no timeout.
* **Broad domains.** The two-label minimum does not stop a subtree alias whose base is itself a public suffix, such as `.co.uk`. This adds no exposure beyond what registering such a domain already allows. A user who runs `container system dns create com` sends every name under `com` to the container DNS server, which answers NXDOMAIN for the ones it does not know, with or without aliases. A subtree alias also needs the container to own the base as its hostname or as an exact alias.
* **Other kinds of container.** Container machines and the builder build attachment configurations without aliases.

## Possible future work

* A create-time warning when an alias is not covered by a registered regular domain.
* Concurrent helper calls in the lookup, and a timeout for each helper call.
* Alias support for container machines.
* A shared library for the alias matching code that third-party helpers can link.
* Showing aliases in list output.
