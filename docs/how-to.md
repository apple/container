# How-to

> [!IMPORTANT]
> This file contains documentation for the CURRENT BRANCH. To find documentation for official releases, find the target release on the [Release Page](https://github.com/apple/container/releases) and click the tag corresponding to your release version. 
>
> Example: [release 0.4.1 tag](https://github.com/apple/container/tree/0.4.1)

How to use the features of `container`.

## Configure memory and CPUs for your containers

Since the containers created by `container` are lightweight virtual machines, consider the needs of your containerized application when you use `container run`.  The `--memory` and `--cpus` options allow you to override the default memory and CPU limits for the virtual machine. The default values are 1 gigabyte of RAM and 4 CPUs. You can use abbreviations for memory units; for example, to run a container for image `big` with 8 CPUs and 32 GiBytes of memory, use:

```bash
container run --rm --cpus 8 --memory 32g big
```

## Configure memory and CPUs for large builds

When you first run `container build`, `container` starts a *builder*, which is a utility container that builds images from your `Dockerfile`s. As with anything you run with `container run`, the builder runs in a lightweight virtual machine, so for resource-intensive builds, you may need to increase the memory and CPU limits for the builder VM.

By default, the builder VM receives 2 GiBytes of RAM and 2 CPUs. You can change these limits by starting the builder container before running `container build`:

```bash
container builder start --cpus 8 --memory 32g
```

If your builder is already running and you need to modify the limits, just stop, delete, and restart the builder:

```bash
container builder stop
container builder delete
container builder start --cpus 8 --memory 32g
```

## Share host files with your container

With the `--volume` option of `container run`, you can share data between the host system and one or more containers, and you can persist data across multiple container runs. The volume option allows you to mount a folder on your host to a filesystem path in the container.

This example mounts a folder named `assets` on your Desktop to the directory `/content/assets` in a container:

<pre>
% ls -l ~/Desktop/assets
total 8
-rw-r--r--@ 1 fido  staff  2410 May 13 18:36 link.svg
% container run --volume ${HOME}/Desktop/assets:/content/assets docker.io/python:alpine ls -l /content/assets
total 4
-rw-r--r-- 1 root root 2410 May 14 01:36 link.svg
%
</pre>

The argument to `--volume` in the example consists of the full pathname for the host folder and the full pathname for the mount point in the container, separated by a colon.

The `--mount` option uses a comma-separated `key=value` syntax to achieve the same result:

<pre>
% container run --mount source=${HOME}/Desktop/assets,target=/content/assets docker.io/python:alpine ls -l /content/assets
total 4
-rw-r--r-- 1 root root 2410 May 14 01:36 link.svg
%
</pre>

## Build and run a multiplatform image

Using the [project from the tutorial example](tutorial.md#set-up-a-simple-project), you can create an image to use both on Apple silicon Macs and on x86-64 servers.

When building the image, just add `--arch` options that direct the builder to create an image supporting both the `arm64` and `amd64` architectures:

```bash
container build --arch arm64 --arch amd64 --tag registry.example.com/fido/web-test:latest --file Dockerfile .
```

Try running the command `uname -a` with the `arm64` variant of the image to see the system information that the virtual machine reports:

<pre>
% container run --arch arm64 --rm registry.example.com/fido/web-test:latest uname -a
Linux 7932ce5f-ec10-4fbe-a2dc-f29129a86b64 6.1.68 #1 SMP Mon Mar 31 18:27:51 UTC 2025 aarch64 GNU/Linux
%
</pre>

When you run the command with the `amd64` architecture, the x86-64 version of `uname` runs under Rosetta translation, so that you will see information for an x86-64 system:

<pre>
% container run --arch amd64 --rm registry.example.com/fido/web-test:latest uname -a
Linux c0376e0a-0bfd-4eea-9e9e-9f9a2c327051 6.1.68 #1 SMP Mon Mar 31 18:27:51 UTC 2025 x86_64 GNU/Linux
%
</pre>

The command to push your multiplatform image to a registry is no different than that for a single-platform image:

```bash
container image push registry.example.com/fido/web-test:latest
```

## Get container or image details

`container image list` and `container list` provide basic information for all of your images and containers. You can also use `list` and `inspect` commands to print detailed JSON output for one or more resources.

Use the `inspect` command and send the result to the `jq` command to get pretty-printed JSON for the images or containers that you specify:

<pre>
% container image inspect web-test | jq
[
  {
    "name": "web-test:latest",
    "variants": [
      {
        "platform": {
          "os": "linux",
          "architecture": "arm64"
        },
        "config": {
          "created": "2025-05-08T22:27:23Z",
          "architecture": "arm64",
...
% container inspect my-web-server | jq
[
  {
    "status": "running",
    "networks": [
      {
        "address": "192.168.64.3/24",
        "gateway": "192.168.64.1",
        "hostname": "my-web-server.test.",
        "network": "default"
      }
    ],
    "configuration": {
      "mounts": [],
      "hostname": "my-web-server",
      "id": "my-web-server",
      "resources": {
        "cpus": 4,
        "memoryInBytes": 1073741824,
      },
...
</pre>

Use the `list` command with the `--format` option to display information for all images or containers. In this example, the `--all` option shows stopped as well as running containers, and `jq` selects the IP address for each running container:

<pre>
% container ls --format json --all | jq '.[] | select ( .status == "running" ) | [ .configuration.id, .networks[0].address ]'
[
  "my-web-server",
  "192.168.64.3/24"
]
[
  "buildkit",
  "192.168.64.2/24"
]
</pre>

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

To verify the MAC address is set correctly, run `ip addr show` inside the container:

```console
% container run --rm --network default,mac=02:42:ac:11:00:02 ubuntu:latest ip addr show eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff
    inet 192.168.64.2/24 brd 192.168.64.255 scope global eth0
       valid_lft forever preferred_lft forever
```

If you don't specify a MAC address, `container` will generate one for you. The generated address has a first nibble set to hexadecimal `f` (`fX:XX:XX:XX:XX:XX`) in case you want to minimize the very small chance of conflict between your MAC address and generated addresses. 

## Mount your host SSH authentication socket in your container

Use the `--ssh` option to mount the macOS SSH authentication socket into your container, so that you can clone private git repositories and perform other tasks requiring passwordless SSH authentication.

When you use `--ssh`, it performs the equivalent of the options `--volume "${SSH_AUTH_SOCK}:/run/host-services/ssh-auth.sock" --env SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock"`. The added benefit of `--ssh` is that when you stop your container, log out, log back in, and restart your container, the system automatically updates the target path for the socket mount to the new value of `SSH_AUTH_SOCK`, so that socket forwarding continues to function.

```console
% container run -it --rm --ssh alpine:latest sh 
/ # env
SHLVL=1
HOME=/root
TERM=xterm
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock
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
ID             IMAGE            OS     ARCH   STATE    ADDR
my-web-server  web-test:latest  linux  arm64  running  192.168.65.2
```

You can delete networks that you create once no containers are attached:

```bash
container stop my-web-server
container network delete foo
```

Networks support both IPv4 and IPv6. When creating a network without explicit subnet options, the system uses default values if configured via system properties (see below), or automatically allocates subnets. The system validates that custom subnets don't overlap with existing networks.

## Configure default network subnets

You can customize the default IPv4 and IPv6 subnets used for new networks using system properties.

### Set default IPv4 subnet

```bash
container system property set network.subnet 192.168.100.1/24
```

### Set default IPv6 prefix

```bash
container system property set network.subnetv6 fd00:abcd::/64
```

These settings apply to networks created without explicit `--subnet` or `--subnet-v6` options.

## View container logs

The `container logs` command displays the output from your containerized application:

<pre>
% container run -d --name my-web-server --rm registry.example.com/fido/web-test:latest
my-web-server
% curl http://my-web-server.test
&lt;!DOCTYPE html>&lt;html>&lt;head>&lt;title>Hello&lt;/title>&lt;/head>&lt;body>&lt;h1>Hello, world!&lt;/h1>&lt;/body>&lt;/html>
% container logs my-web-server
192.168.64.1 - - [15/May/2025 03:00:03] "GET / HTTP/1.1" 200 -
%
</pre>

Use the `--boot` option to see the logs for the virtual machine boot and init process:

<pre>
% container logs --boot my-web-server
[    0.098284] cacheinfo: Unable to detect cache hierarchy for CPU 0
[    0.098466] random: crng init done
[    0.099657] brd: module loaded
[    0.100707] loop: module loaded
[    0.100838] virtio_blk virtio2: 1/0/0 default/read/poll queues
[    0.101051] virtio_blk virtio2: [vda] 1073741824 512-byte logical blocks (550 GB/512 GiB)
...
[    0.127467] EXT4-fs (vda): mounted filesystem without journal. Quota mode: disabled.
[    0.127525] VFS: Mounted root (ext4 filesystem) readonly on device 254:0.
[    0.127635] devtmpfs: mounted
[    0.127773] Freeing unused kernel memory: 2816K
[    0.143252] Run /sbin/vminitd as init process
2025-05-15T02:24:08+0000 info vminitd : [vminitd] vminitd booting...
2025-05-15T02:24:08+0000 info vminitd : [vminitd] serve vminitd api
2025-05-15T02:24:08+0000 debug vminitd : [vminitd] starting process supervisor
2025-05-15T02:24:08+0000 debug vminitd : port=1024 [vminitd] booting grpc server on vsock
...
2025-05-15T02:24:08+0000 debug vminitd : exits=[362: 0] pid=363 [vminitd] checking for exit of managed process
2025-05-15T02:24:08+0000 debug vminitd : [vminitd] waiting on process my-web-server
[    1.122742] IPv6: ADDRCONF(NETDEV_CHANGE): eth0: link becomes ready
2025-05-15T02:24:39+0000 debug vminitd : sec=1747275879 usec=478412 [vminitd] setTime
%
</pre>

## Monitor container resource usage

The `container stats` command displays real-time resource usage statistics for your running containers, similar to the `top` command for processes. This is useful for:
- Monitoring CPU and memory consumption
- Tracking network and disk I/O
- Identifying resource-intensive containers
- Verifying container resource limits are appropriate

By default, `container stats` shows live statistics for all running containers in an interactive display:

```console
% container stats
Container ID    Cpu %    Memory Usage           Net Rx/Tx              Block I/O               Pids
my-web-server   2.45%    45.23 MiB / 1.00 GiB   1.23 MiB / 856.00 KiB  4.50 MiB / 2.10 MiB     3
db              125.12%  512.50 MiB / 2.00 GiB  5.67 MiB / 3.21 MiB    125.00 MiB / 89.00 MiB  12
```

To monitor specific containers, provide their names or IDs:

```console
% container stats my-web-server db
```

For a single snapshot (non-interactive), use the `--no-stream` flag:

```console
% container stats --no-stream my-web-server
Container ID    Cpu %    Memory Usage          Net Rx/Tx              Block I/O              Pids
my-web-server   30.45%    45.23 MiB / 1.00 GiB  1.23 MiB / 856.00 KiB  4.50 MiB / 2.10 MiB    3
```

You can also output statistics in JSON format for scripting:

```console
% container stats --format json --no-stream my-web-server | jq
[
  {
    "id": "my-web-server",
    "memoryUsageBytes": 47431680,
    "memoryLimitBytes": 1073741824,
    "cpuUsageUsec": 1234567,
    "networkRxBytes": 1289011,
    "networkTxBytes": 876544,
    "blockReadBytes": 4718592,
    "blockWriteBytes": 2202009,
    "numProcesses": 3
  }
]
```

**Understanding the metrics:**

- **Cpu %**: Percentage of CPU usage. ~100% = one fully utilized core. A multi-core container can show > 100%.
- **Memory Usage**: Current memory usage vs. the container's memory limit.
- **Net Rx/Tx**: Network bytes received and transmitted.
- **Block I/O**: Disk bytes read and written.
- **Pids**: Number of processes running in the container.

## Expose virtualization capabilities to a container

> [!NOTE]
> This feature requires a M3 or newer Apple silicon machine and a Linux kernel that supports virtualization. For a kernel configuration that has all of the right features enabled, see https://github.com/apple/containerization/blob/0.5.0/kernel/config-arm64#L602.

You can enable virtualization capabilities in containers by using the `--virtualization` option of `container run` and `container create`.

If your machine does not have support for nested virtualization, you will see the following:

```console
container run --name nested-virtualization --virtualization --kernel /path/to/a/kernel/with/virtualization/support --rm ubuntu:latest sh -c "dmesg | grep kvm"
Error: unsupported: "nested virtualization is not supported on the platform"
```

When nested virtualization is enabled successfully, `dmesg` will show output like the following:

```console
container run --name nested-virtualization --virtualization --kernel /path/to/a/kernel/with/virtualization/support --rm ubuntu:latest sh -c "dmesg | grep kvm"
[    0.017245] kvm [1]: IPA Size Limit: 40 bits
[    0.017499] kvm [1]: GICv3: no GICV resource entry
[    0.017501] kvm [1]: disabling GICv2 emulation
[    0.017506] kvm [1]: GIC system register CPU interface enabled
[    0.017685] kvm [1]: vgic interrupt IRQ9
[    0.017893] kvm [1]: Hyp mode initialized successfully
```

## Use a custom init image

The `--init-image` flag allows you to specify a custom init filesystem image for the lightweight VM that runs your container. This enables:

- Custom boot-time logic before the OCI container starts
- Running additional processes and daemons (e.g., eBPF network filters, logging agents) inside the VM
- Debugging or instrumenting the init process

### Create a custom init image

A custom init image wraps the default `vminitd` binary, allowing you to run custom logic before handing off to the standard init process.

**1. Create a wrapper binary (example in Go for easy cross-compilation):**

```go
// wrapper.go
package main

import (
    "os"
    "syscall"
)

func main() {
    // Write a message to kernel log
    kmsg, err := os.OpenFile("/dev/kmsg", os.O_WRONLY, 0)
    if err == nil {
        kmsg.WriteString("<6>custom-init: === CUSTOM INIT IMAGE RUNNING ===\n")
        kmsg.Close()
    }

    // Execute the real vminitd
    err = syscall.Exec("/sbin/vminitd.real", os.Args, os.Environ())
    if err != nil {
        os.Exit(1)
    }
}
```

**2. Build the wrapper for Linux arm64:**

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o wrapper wrapper.go
```

**3. Create a Containerfile:**

```dockerfile
FROM ghcr.io/apple/containerization/vminit:latest AS base

FROM ghcr.io/apple/containerization/vminit:latest
COPY --from=base /sbin/vminitd /sbin/vminitd.real
COPY wrapper /sbin/vminitd
```

**4. Build the custom init image:**

```bash
container build -t local/custom-init:latest .
```

### Run a container with a custom init image

```bash
container run --name my-container --init-image local/custom-init:latest alpine:latest echo "hello"
```

### Verify the custom init is running

Check the VM boot logs to confirm your custom init code executed:

```console
% container logs --boot my-container | grep custom-init
[    0.129230] custom-init: === CUSTOM INIT IMAGE RUNNING ===
```

## Configure system properties

The `container system property` subcommand manages the configuration settings for the `container` CLI and services. You can customize various aspects of container behavior, including build settings, default images, and network configuration.

Use `container system property list` to show information for all available properties:

```console
% bin/container system property ls
ID                 TYPE    VALUE                                     DESCRIPTION
build.rosetta      Bool    true                                      Build amd64 images on arm64 using Rosetta, instead of QEMU.
dns.domain         String  *undefined*                               If defined, the local DNS domain to use for containers with unqualified names.
image.builder      String  ghcr.io/apple/container-builder-shim/...  The image reference for the utility container that `container build` uses.
image.init         String  ghcr.io/apple/containerization/vminit...  The image reference for the default initial filesystem image.
kernel.binaryPath  String  opt/kata/share/kata-containers/vmlinu...  If the kernel URL is for an archive, the archive member pathname for the kernel file.
kernel.url         String  https://github.com/kata-containers/ka...  The URL for the kernel file to install, or the URL for an archive containing the kernel file.
network.subnet     String  *undefined*                               Default subnet for IPv4 allocation.
network.subnetv6   String  *undefined*                               Default IPv6 network prefix.
```

### Example: Disable Rosetta for builds

If you want to prevent the use of Rosetta translation during container builds on Apple Silicon Macs:

```bash
container system property set build.rosetta false
```

This is useful when you want to ensure builds only produce native arm64 images and avoid any x86_64 emulation.

## View system logs

The `container system logs` command allows you to look at the log messages that `container` writes:

<pre>
% container system logs | tail -8
2025-06-02 16:46:11.560780-0700 0xf6dc5    Info        0x0                  61684  0    container-apiserver: [com.apple.container:APIServer] Registering plugin [id=com.apple.container.container-runtime-linux.my-web-server]
2025-06-02 16:46:11.699095-0700 0xf6ea8    Info        0x0                  61733  0    container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] starting container-runtime-linux [uuid=my-web-server]
2025-06-02 16:46:11.699125-0700 0xf6ea8    Info        0x0                  61733  0    container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] configuring XPC server [uuid=my-web-server]
2025-06-02 16:46:11.700908-0700 0xf6ea8    Info        0x0                  61733  0    container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] starting XPC server [uuid=my-web-server]
2025-06-02 16:46:11.703028-0700 0xf6ea8    Info        0x0                  61733  0    container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] `bootstrap` xpc handler [uuid=my-web-server]
2025-06-02 16:46:11.720836-0700 0xf6dc3    Info        0x0                  61689  0    container-network-vmnet: [com.apple.container:NetworkVmnetHelper] allocated attachment [hostname=my-web-server.test.] [address=192.168.64.2/24] [gateway=192.168.64.1] [id=default]
2025-06-02 16:46:12.293193-0700 0xf6eaa    Info        0x0                  61733  0    container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] `start` xpc handler [uuid=my-web-server]
2025-06-02 16:46:12.368723-0700 0xf6e93    Info        0x0                  61684  0    container-apiserver: [com.apple.container:APIServer] Handling container my-web-server Start.
%
</pre>

## Generating and installing completion scripts

### Overview

The `container --generate-completion-script [zsh|bash|fish]` command generates completion scripts for the provided shell. Below is a detailed guide on how to install the completion scripts.

> [!NOTE]
> See the [swift-argument-parser documentation](https://apple.github.io/swift-argument-parser/documentation/argumentparser/installingcompletionscripts/#Installing-Zsh-Completions) for more information about generating and installing shell completion scripts.

### Installing `zsh` completions

If you have [oh-my-zsh](https://ohmyz.sh/) installed, you already have a directory of automatically loaded completion scripts — `.oh-my-zsh/completions`. Copy your new completion script to that directory. If the `completions` directory does not exist, simply make it.

```zsh
mkdir -p ~/.oh-my-zsh/completions
container --generate-completion-script zsh > ~/.oh-my-zsh/completions/_container
source ~/.oh-my-zsh/completions/_container
```

> [!NOTE]
> Your completion script must have the filename `_container`.

Without oh-my-zsh, you’ll need to add a path for completion scripts to your function path, and turn on completion script autoloading. First, add these lines to your `~/.zshrc` file:

```bash
fpath=(~/.zsh/completion $fpath)
autoload -U compinit
compinit
```

Next, create a directory at `~/.zsh/completion` and copy the completion script to the new directory.

```zsh
mkdir -p ~/.zsh/completion
container --generate-completion-script zsh > ~/.zsh/completion/_container
source ~/.zshrc
```

### Installing `bash` completions

If you have [bash-completion](https://github.com/scop/bash-completion) installed, you can just copy your new completion script to the `bash_completion.d` directory.

> [!NOTE]
> The path to the directory is dependent on how bash-completion was installed. Find the correct path and then copy the completion script there. For example, if you used homebrew to install `bash-completion`:
>  ```bash
>  container --generate-completion-script bash > /opt/homebrew/etc/bash_completion.d/container
>  source /opt/homebrew/etc/bash_completion.d/container
>  ```

Without bash-completion, you’ll need to source the completion script directly. Create and copy it to a directory such as `~/.bash_completions`. 

```bash
mkdir -p ~/.bash_completions
container --generate-completion-script bash >  ~/.bash_completions/container
source ~/.bash_completions/container
```

Furthermore, you can add the following line to `~/.bash_profile` or `~/.bashrc`, in order for every new bash session to have autocompletion ready.

```bash
source ~/.bash_completions/container
```

### Installing `fish` completions

Copy the completion script to any path listed in the environment variable `$fish_completion_path`.

```bash
container --generate-completion-script fish > ~/.config/fish/completions/container.fish
```
