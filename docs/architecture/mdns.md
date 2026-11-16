# mDNS architecture

This document describes how `container` advertises a container's mDNS services on the host's networks. It covers:

* Why a container's own announcements are not enough
* The components that advertise a service for a container
* The path of a service from the container to the network
* The invariants that the implementation relies on
* The security properties of the design

For user-level instructions, see [Networking](../networking.md#advertise-a-containers-services-on-your-local-network).

## Background

A container runs in its own virtual machine, attached to a vmnet network. The host has an interface on that network, such as `bridge100`, which holds the gateway address.

An application in the container that announces a service with mDNS sends its announcements to the multicast group on the container's network. Those announcements reach the host's mDNS responder on the host's interface for that network, and the host can browse and resolve the service there. They go no further, for two reasons:

* Multicast is link-local. Nothing forwards it from the container's network to the host's other networks.
* The announcement names the container's host name and address. A device on another network could not connect to that address even if it saw the announcement.

A device elsewhere can reach the container only through a published port, at the host's address. Advertising a container's service therefore means advertising a different thing than the container announces: the same service name and metadata, at the host's name and the published host port.

## Components

* **The `--mdns` option.** `container create` and `container run` store it as `ContainerConfiguration.mdns`. It is off by default and has no effect without a published port, which the CLI reports as an error.
* **The reflector.** `MDNSReflector`, in the module of the same name, runs in the runtime helper of a container that has the option set. The helper starts it after the port forwarders and stops it when the container is cleaned up, so it lives exactly as long as the published ports do. It is split into three parts:
  * `ReflectorCore` is the state machine. It decides what to discover, which services belong to the container, and where each one is registered.
  * `ReflectionPolicy` holds the rules that map a service to host interfaces and a host port. It has no state.
  * `DNSSDServiceDiscovery` performs the DNS-SD operations that the core asks for: browse, resolve, look up an address and register. It is the only part that talks to the system, through the `ServiceDiscovery` protocol.
* **The host's mDNS responder.** The reflector implements no mDNS of its own. It asks `mDNSResponder` to browse on one interface and to register on others, through the DNS-SD API. The responder does the probing, announcing, conflict handling and answering.

## Reflecting a service

1. The reflector finds the host's interface on the container's network, which is the interface that holds the gateway address of the container's first attachment. If that interface does not exist yet, the reflector waits for it.
2. It asks the responder to enumerate the service types that are advertised on that interface, with the DNS-SD query for `_services._dns-sd._udp`. A type whose transport has no published port is ignored.
3. For each type it browses for instances, and it resolves each instance to a host name, a port and a TXT record. The resolution stays active, so a later change to any of the three is reported.
4. It looks up the IPv4 address of the host name. The service belongs to the container only when that address is the container's address. Anything else is left alone, which matters because the host's own services and the services of other containers are visible on the same interface.
5. `ReflectionPolicy` selects the host interfaces to advertise on and the host port for each one. An interface qualifies when a published port forwards to the service's port and listens on an address of that interface. When several qualifying interfaces are on the same network, one of them is selected.
6. The reflector registers the service on each selected interface, with the same instance name, type and TXT record, the host port, and no host name, so that it resolves to the host's own name and addresses on that interface.

After that the reflector keeps the registrations in step with the container:

* A changed TXT record replaces the TXT record of the registrations.
* A changed port moves the registrations to the host port that forwards to the new port, or withdraws them if there is none.
* A changed host name puts the service back to step 4.
* A service that the container no longer announces is withdrawn.
* A change to the host's interfaces repeats step 5, which adds registrations on new interfaces and withdraws them from interfaces that are gone.

## Invariants

* **Never on the container's network.** A service is not registered on the interface that it was discovered on. The container owns the instance name there, so a second registration would conflict with it: the responder would rename the host's copy, or refuse it. Registrations are therefore made per interface and not on all interfaces at once.
* **Once per network.** A service is registered on at most one interface for each IP network. A host with two interfaces on one network, such as Wi-Fi and Ethernet, hears each of its registrations on the other interface. Two registrations of one name are safe only while their records are identical, and an update of the TXT record reaches them at slightly different times, so the responder can take its own second copy for a conflict and rename it. An interface that already carries the service is kept in preference to another on the same network, so a new interface does not move the service.
* **Only the container's own services.** A service is reflected only after its host name has resolved to the container's address. Until then nothing is registered, and an empty answer is not taken as a decision.
* **Only reachable services.** A service is registered on an interface only when a published port makes it reachable there. A service on an unpublished port, or on a port published on a loopback address, is not advertised anywhere.
* **The advertised port is the host port.** The port in a registration always comes from a published port, never from the container's announcement.
* **Registrations live as long as the service.** They are withdrawn when the container stops announcing the service and when the container stops, because the helper stops the reflector as part of cleanup. If the helper exits, the responder drops its registrations with it.
* **The reflector is confined to one queue.** The core, the discovery backend and the interface monitor all run on one serial queue, so the state machine needs no locks, and an operation that is cancelled on that queue receives no further results.
* **Existing configurations stay valid.** The `mdns` key of a container configuration is optional when it is decoded, so a configuration stored before the option existed decodes with it off.

## Security considerations

* Advertisement is opt-in for each container. Without `--mdns` nothing is browsed or registered.
* The option adds no reachability. Every advertised port is one that the user has already published on an address that the network can reach. What it adds is discoverability: devices on the network learn that the service exists.
* The contents of an advertisement come from the workload. The instance name and the TXT record are whatever the application in the container announces, and they are passed on unchanged. A workload can therefore choose the name and metadata that appear on the network for its own published ports. It cannot choose the host name, the address or the port, and it cannot advertise a port that is not published to it.
* A workload cannot have another container's services advertised or withdrawn. The ownership check uses the address that the network helper allocated, which a container cannot take from another.
* The reflector registers services of the host's own name only. It registers no host names or address records, so it cannot be used to redirect a name.
* The number of services that a workload can cause to be registered is not limited. Each registration costs the responder a small amount of memory and some multicast traffic.

## Known limitations

* **First attachment only.** Services are discovered on the network of the container's first attachment, because published ports forward to it.
* **IPv4 ownership.** A service whose host name has no IPv4 address is not recognized as the container's.
* **Type enumeration.** A responder in the container that does not answer the service type enumeration query is not discovered.
* **No subtypes.** A service is registered under its primary type. Subtype registrations are not carried over.
* **Address families.** A service is registered as provided by the host, so it resolves to the host's IPv4 and IPv6 addresses on the interface. A port published on an IPv4 address accepts IPv4 connections only, so a client that tries IPv6 first has to fall back.
* **Name conflicts on the network.** If the instance name is taken on a host network, the responder registers the service under a name with a numeric suffix. The reflector logs this and does not report it to the user.
* **Interfaces on one link with different networks.** Interfaces are taken to share a link when they share an IP subnet, link-local subnets aside. Two interfaces on one link that have no subnet in common each get a registration, with the renaming risk described under the invariants.
* **One host port per interface.** When more than one published port forwards to a service's port on an interface, the first one is advertised.
* **Other kinds of container.** Container machines and the builder do not offer the option.

## Possible future work

* A system configuration default, so that advertisement can be on for every container.
* Showing the advertised services in `container inspect`.
* Carrying over subtypes.
* Registering an address record for the published address family only.
