# Host integration

Bridge your container and your Mac: forward your SSH agent in, or reach a host
service from inside a container.

## Mount your host SSH authentication socket in your container

Use the `--ssh` option to mount the macOS SSH authentication socket into your container, so that you can clone private git repositories and perform other tasks requiring passwordless SSH authentication.

When you use `--ssh`, it performs the equivalent of the options `--volume "${SSH_AUTH_SOCK}:/var/host-services/ssh-auth.sock" --env SSH_AUTH_SOCK=/var/host-services/ssh-auth.sock"`. The added benefit of `--ssh` is that when you stop your container, log out, log back in, and restart your container, the system automatically updates the target path for the socket mount to the new value of `SSH_AUTH_SOCK`, so that socket forwarding continues to function.

```console
% container run -it --rm --ssh alpine:latest sh 
/ # env
SHLVL=1
HOME=/root
TERM=xterm
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SSH_AUTH_SOCK=/var/host-services/ssh-auth.sock
PWD=/
/ # apk add openssh-client
(1/6) Installing openssh-keygen (10.0_p1-r7)
(2/6) Installing ncurses-terminfo-base (6.5_p20250503-r0)
(3/6) Installing libncursesw (6.5_p20250503-r0)
(4/6) Installing libedit (20250104.3.1-r1)
(5/6) Installing openssh-client-common (10.0_p1-r7)
(6/6) Installing openssh-client-default (10.0_p1-r7)
Executing busybox-1.37.0-r18.trigger
OK: 12 MiB in 22 packages
/ # ssh-add -l
...auth key output...
/ # apk add git
(1/12) Installing brotli-libs (1.1.0-r2)
(2/12) Installing c-ares (1.34.5-r0)
(3/12) Installing libunistring (1.3-r0)
(4/12) Installing libidn2 (2.3.7-r0)
(5/12) Installing nghttp2-libs (1.65.0-r0)
(6/12) Installing libpsl (0.21.5-r3)
(7/12) Installing zstd-libs (1.5.7-r0)
(8/12) Installing libcurl (8.14.1-r1)
(9/12) Installing libexpat (2.7.1-r0)
(10/12) Installing pcre2 (10.43-r1)
(11/12) Installing git (2.49.1-r0)
(12/12) Installing git-init-template (2.49.1-r0)
Executing busybox-1.37.0-r18.trigger
OK: 24 MiB in 34 packages
/ # git clone git@github.com:some-org/some-private-repo.git
Cloning into 'some-private-repo'...
...
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

This uses the same underlying DNS mechanism described in [Networking: Set up DNS-based
container names](./networking.md#set-up-dns-based-container-names), just with
`--localhost` pointing the domain at a host address instead of a container.
