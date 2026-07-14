# Networking

Learn how `container` networks containers with one another, with the host, and with
external systems.

## Overview

Running `container system start` creates a vmnet network named `default`, to which your
containers attach unless you specify otherwise. Every container on a network receives a
DNS name reachable from the host and from other containers on the same network. The
domain suffix comes from the `[dns] domain` setting in `~/.config/container/config.toml`
(see [`config.toml` reference](./container-system-config.md#dns)) — for example, with
`domain = "test"` set, a container named `my-web-server` is reachable at
`my-web-server.test`.

## Container-to-container networking

From one container, use another container's DNS name to reach a service it exposes:

```bash
container run --rm -d --name http-server python:alpine python3 -m http.server
container run -it --rm alpine/curl curl -v http://http-server.test:8000
container stop http-server
```

## Forward traffic from `localhost` to your container

Use the `--publish` option to forward TCP or UDP traffic from your loopback IP to the container you run. The option value has the form `[host-ip:]host-port:container-port[/protocol]`, where protocol may be `tcp` or `udp`, case insensitive.

If your container attaches to multiple networks, the ports you publish forward to the IP address of the interface attached to the first network.

To forward requests from port 8080 on the IPv4 loopback IP to a NodeJS webserver on container port 8000, run:

```bash
container run -d --rm -p 127.0.0.1:8080:8000 node:latest npx http-server -a :: -p 8000
```

Test access using `curl`:

```console
% curl http://127.0.0.1:8080
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width">
    <title>Index of /</title>
...
<br><address>Node.js v25.2.1/ <a href="https://github.com/http-party/http-server">http-server</a> server running @ 127.0.0.1:8080</address>
</body></html>
```

To forward requests from port 8080 on the IPv6 loopback IP to a NodeJS webserver on container port 8000, run:

```bash
container run -d --rm -p '[::1]:8080:8000' node:latest npx http-server -a :: -p 8000
```

Test access using `curl`:

```console
% curl -6 'http://[::1]:8080'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width">
    <title>Index of /</title>
...
<br><address>Node.js v25.2.1/ <a href="https://github.com/http-party/http-server">http-server</a> server running @ [::1]:8080</address>
</body></html>
```

## Access a host service from a container

> [!IMPORTANT]
> Due to macOS security constraints around packet filter rules, this feature has limited functionality:
> - Creating a localhost domain disables Private Relay.
> - The local domain packet filter rule is removed on a restart.

Create a DNS domain with `--localhost <ipv4-address>` to make a domain used by a container to access a host service. Any IPv4 address can be used as `<ipv4-address>`, which will be assigned to the domain name in container.

Choose an IP address that is least likely to conflict with any networks or reserved IP addresses in your environment. Reasonably safe address ranges include:

- The documentation ranges 192.0.2.0/24, 198.51.100.0/24, and 203.0.113.0/24.
- The 172.16.0.0/12 private range.

To connect a host HTTP server from a container, run:

```bash
mkdir -p /tmp/test; cd /tmp/test; echo "hello" > index.html
python3 -m http.server 8000 --bind 127.0.0.1
```

Create a domain for host connection:

```bash
sudo container system dns create host.container.internal --localhost 203.0.113.113
```

Test access to the host HTTP server from a container:

```console
% container run -it --rm alpine/curl curl http://host.container.internal:8000
hello
```

## Set a custom MAC address for your container

Use the `mac` option to specify a custom MAC address for your container's network interface. This is useful for:
- Network testing scenarios requiring predictable MAC addresses
- Consistent network configuration across container restarts

The MAC address must be in the format `XX:XX:XX:XX:XX:XX` (with colons or hyphens as separators). Set the two least significant bits of the first octet to `10` (locally signed, unicast address). 

```bash
container run --network default,mac=02:42:ac:11:00:02 ubuntu:latest
```

To verify the MAC address is set correctly, read the interface MAC directly from sysfs inside the container:

```console
% container run --rm --network default,mac=02:42:ac:11:00:02 ubuntu:latest cat /sys/class/net/eth0/address
02:42:ac:11:00:02
```

If you don't specify a MAC address, `container` will generate one for you. The generated address has a first nibble set to hexadecimal `f` (`fX:XX:XX:XX:XX:XX`) in case you want to minimize the very small chance of conflict between your MAC address and generated addresses. 

## Create and use a separate isolated network

> [!NOTE]
> This feature is available on macOS 26 and later.

Running `container system start` creates a vmnet network named `default` to which your containers will attach unless you specify otherwise.

You can create a separate isolated network using `container network create`.

This command creates a network named `foo`:

```bash
container network create foo
```

You can also specify custom IPv4 and IPv6 subnets when creating a network:

```bash
container network create foo --subnet 192.168.100.0/24 --subnet-v6 fd00:1234::/64
```

The `foo` network, the default network, and any other networks you create are isolated from one another. A container on one network has no connectivity to containers on other networks.

Run `container network list` to see the networks that exist:

```console
% container network list
NETWORK  STATE    SUBNET
default  running  192.168.64.0/24
foo      running  192.168.65.0/24
%
```

Run a container that is attached to that network using the `--network` flag:

```console
container run -d --name my-web-server --network foo --rm web-test
```

Use `container ls` to see that the container is on the `foo` subnet:

```console
 % container ls
ID             IMAGE            OS     ARCH   STATE    IP
my-web-server  web-test:latest  linux  arm64  running  192.168.65.2
```

You can delete networks that you create once no containers are attached:

```bash
container stop my-web-server
container network delete foo
```

Networks support both IPv4 and IPv6. When creating a network without explicit subnet options, the system uses default values if configured via system properties (see below), or automatically allocates subnets. The system validates that custom subnets don't overlap with existing networks.

## Configure default network subnets

You can customize the default IPv4 and IPv6 subnets used for new networks by editing your runtime configuration file at `~/.config/container/config.toml`:

```toml
[network]
subnet = "192.168.100.1/24"
subnetv6 = "fd00:abcd::/64"
```

These settings apply to networks created without explicit `--subnet` or `--subnet-v6` options.
