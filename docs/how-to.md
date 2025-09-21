# How-to

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

To forward requests from `localhost:8080` to a Python webserver on container port 8000, run:

```bash
container run -d --rm -p 127.0.0.1:8080:8000 python:slim python3 -m http.server --bind 0.0.0.0 8000
```

A `curl` to `localhost:8000` outputs:

```console
% curl http://localhost:8080                                                                                    
<!DOCTYPE HTML>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Directory listing for /</title>
</head>
<body>
<h1>Directory listing for /</h1>
<hr>
<ul>
<li><a href="bin/">bin@</a></li>
<li><a href="boot/">boot/</a></li>
<li><a href="dev/">dev/</a></li>
<li><a href="etc/">etc/</a></li>
<li><a href="home/">home/</a></li>
<li><a href="lib/">lib@</a></li>
<li><a href="lost%2Bfound/">lost+found/</a></li>
<li><a href="media/">media/</a></li>
<li><a href="mnt/">mnt/</a></li>
<li><a href="opt/">opt/</a></li>
<li><a href="proc/">proc/</a></li>
<li><a href="root/">root/</a></li>
<li><a href="run/">run/</a></li>
<li><a href="sbin/">sbin@</a></li>
<li><a href="srv/">srv/</a></li>
<li><a href="sys/">sys/</a></li>
<li><a href="tmp/">tmp/</a></li>
<li><a href="usr/">usr/</a></li>
<li><a href="var/">var/</a></li>
</ul>
<hr>
</body>
</html>
```

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
network.subnet     String  *undefined*                               Default subnet for IP allocation (used on macOS 15 only).
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

## Setup shell completion

The `container --generate-completion-script [zsh|bash|fish]` command generates completion scripts for the provided shell. 

A detailed guide on how to install the completion scripts can be found [here](https://swiftpackageindex.com/apple/swift-argument-parser/1.5.1/documentation/argumentparser/installingcompletionscripts)
