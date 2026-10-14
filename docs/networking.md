# Networking

Learn how `container` networks containers with one another, with the host, and with
external systems.

Running `container system start` creates a vmnet network named `default`, to which your
containers attach unless you specify otherwise. Every container gets an IP address on
its network, always reachable by that IP from the host and from other containers on the
same network (find it with `container inspect <name>`).

## Set up DNS-based container names

Reaching a container by name instead of IP goes through `container`'s embedded DNS
service. Set this up in two steps:

### Step 1: Tell the `container` service what domain to use

Edit `~/.config/container/config.toml`:

```toml
[dns]
domain = "test"
```

Restart the service so it picks up the change:

```bash
container system stop
container system start
```

From this point on, every container you run gets registered under `<name>.test` inside
`container`'s DNS service, and every container's own DNS resolver is configured to look
up `.test` names there too.

### Step 2: Tell macOS to use that domain too

Step 1 only affects the `container` service and the containers it runs — your Mac's own
DNS resolver still knows nothing about `test`. Point it at `container`'s DNS service:

```bash
sudo container system dns create test
```

Enter your administrator password when prompted. This writes a resolver file to
`/etc/resolver/` that tells macOS: for any `*.test` query, ask `127.0.0.1` instead of
your normal DNS server.

Both steps are needed. See [`[dns]` reference](./container-system-config.md#dns) for the
config-key-level detail.

With both steps done, confirm it end-to-end from your Mac:

```console
% container run -d --rm --name my-web-server python:alpine python3 -m http.server 8000
% curl http://my-web-server.test:8000
```

See [Host integration](./host-integration.md) for the reverse direction — reaching a
service running on your Mac from inside a container.

## Container-to-container networking

From one container, use another container's DNS name to reach a service it exposes.
This requires the DNS setup above ([Set up DNS-based container
names](#set-up-dns-based-container-names)):

```bash
container run --rm -d --name http-server python:alpine python3 -m http.server
container run -it --rm alpine/curl curl -v http://http-server.test:8000
container stop http-server
```

> [!WARNING]
> This works for containers on the `default` network using a domain-qualified name
> (`http-server.test`, as above). It does **not** currently work for looking up another
> container by its *bare* hostname (no domain suffix) on a custom network created with
> `container network create` — the kind of zero-configuration, Compose-style service
> discovery some users expect. That gap is tracked upstream as
> [apple/container#1809](https://github.com/apple/container/issues/1809) (open feature
> request, not yet implemented) and related broader reports in
> [apple/container#856](https://github.com/apple/container/issues/856). Until resolved,
> reach a container on a custom network by its IP address instead (`container inspect
> <name>` to find it).

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
NETWORK  SUBNET
default  192.168.64.0/24
foo      192.168.65.0/24
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

Networks support both IPv4 and IPv6. When creating a network without explicit subnet options, the system uses default values if configured in your runtime configuration file (see [Configure default network subnets](#configure-default-network-subnets)), or automatically allocates subnets. The system validates that custom subnets don't overlap with existing networks.

## Configure default network subnets

You can customize the default IPv4 and IPv6 subnets used for new networks by editing your runtime configuration file at `~/.config/container/config.toml`:

```toml
[network]
subnet = "192.168.100.1/24"
subnetv6 = "fd00:abcd::/64"
```

These settings apply to networks created without explicit `--subnet` or `--subnet-v6` options.
