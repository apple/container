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

See [Volumes](./volumes.md) for bind mounts and named volumes.

## Build and run a multiplatform image

Using the [project from the tutorial example](./tutorials/start-here.md#set-up-a-simple-project), you can create an image to use both on Apple silicon Macs and on x86-64 servers.

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

`container image list` and `container list` provide basic information for all of your images and containers. You can also use `list` and `inspect` commands to print detailed machine-readable output for resources.

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

See [Networking](./networking.md) for how to publish ports, reach the host from a
container, set a custom MAC address, and create isolated networks.

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

## Control Linux capabilities

By default, containers start with a restricted set of Linux capabilities:

`CAP_AUDIT_WRITE`, `CAP_CHOWN`, `CAP_DAC_OVERRIDE`, `CAP_FOWNER`, `CAP_FSETID`, `CAP_KILL`, `CAP_MKNOD`, `CAP_NET_BIND_SERVICE`, `CAP_NET_RAW`, `CAP_SETFCAP`, `CAP_SETGID`, `CAP_SETPCAP`, `CAP_SETUID`, `CAP_SYS_CHROOT`

You can customize the capability set using `--cap-add` and `--cap-drop` with `container run` or `container create`.

Capability names can be specified with or without the `CAP_` prefix, and are case-insensitive:

These are equivalent:
```bash
container run --cap-add CAP_NET_ADMIN alpine ip link set lo down
container run --cap-add NET_ADMIN alpine ip link set lo down
container run --cap-add net_admin alpine ip link set lo down
```

To grant all capabilities:

```bash
container run --cap-add ALL alpine sh -c "ip link set lo down && echo ok"
```

To drop all capabilities and selectively re-add only what you need:

```bash
container run --cap-drop ALL --cap-add SETUID --cap-add SETGID alpine id
```

Adds are processed after drops, so `--cap-drop ALL --cap-add ALL` results in all capabilities being granted.

To grant all capabilities except specific ones:

```bash
container run --cap-add ALL --cap-drop NET_ADMIN alpine sh
```

To drop a single capability from the default set:

```console
% container run --cap-drop CHOWN alpine chown 100 /tmp
chown: /tmp: Operation not permitted
```


## Mask and protect paths inside a container

> [!NOTE]
> `--masked-path` and `--read-only-path` are experimental.  The behavior described here are subject to change in a future release.

By default, containers hide a set of sensitive paths from the workload, and mark another set read-only, matching the OCI runtime spec defaults that other production runtimes apply.

Masked by default (files are replaced with `/dev/null`, directories with an empty read-only tmpfs):

`/proc/asound`, `/proc/acpi`, `/proc/kcore`, `/proc/keys`, `/proc/latency_stats`, `/proc/timer_list`, `/proc/timer_stats`, `/proc/sched_debug`, `/proc/scsi`, `/sys/firmware`, `/sys/devices/virtual/powercap`

Read-only by default:

`/proc/bus`, `/proc/fs`, `/proc/irq`, `/proc/sys`, `/proc/sysrq-trigger`

You can extend either set using `--masked-path` and `--read-only-path` with `container run` or `container create`. Both flags can be repeated, take absolute paths, and add to the defaults rather than replacing them:

```console
% container run --masked-path /etc/alpine-release alpine cat /etc/alpine-release
% container run --read-only-path /tmp alpine touch /tmp/file
touch: /tmp/file: Read-only file system
```

To opt out of the defaults entirely, pass the `NONE` sentinel. It clears every path accumulated so far for that flag, including the defaults:

```bash
container run --masked-path NONE alpine ls /sys/firmware
```

Because values are processed in order, `NONE` can be followed by a custom set that replaces the defaults:

```bash
container run --masked-path NONE --masked-path /run/secrets alpine sh
```

The two flags are independent, so clearing the masked paths leaves the read-only defaults in place. The paths that a container was created with are visible in `container inspect` under `configuration.maskedPaths` and `configuration.readonlyPaths`; when neither flag is used, both are absent and the runtime defaults apply.


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

## Run a container with a provided init process

By default, the command you specify in `container run` runs as PID 1 inside the container. This means it is responsible for reaping zombie processes and handling signals, which many applications are not designed to do. The `--init` flag runs a lightweight init process as PID 1 that automatically forwards signals and reaps orphaned child processes.

```bash
container run --init ubuntu:latest my-app
```

The init process is also available with `container create`:

```bash
container create --init --name my-container ubuntu:latest my-app
container start my-container
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

Use the `vminit` image tag corresponding to the `scVersion` value in the project `Package.swift` file.

Or, use `vminit:latest` if you have a local `containerization` project in [edit mode](../BUILDING.md#develop-using-a-local-copy-of-containerization).

```dockerfile
FROM ghcr.io/apple/containerization/vminit:0.34.0 AS base

FROM ghcr.io/apple/containerization/vminit:0.34.0
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

## Use container machines

Container machines are persistent Linux environments built from OCI images — your home directory is mounted in, the user account matches your host account, and the filesystem survives stop and start. See [container-machine.md](./container-machine.md) for the full guide.

## Configure system properties

The `container system property` subcommand manages the configuration settings for the `container` CLI and services. You can customize various aspects of container behavior, including build settings, default images, and network configuration.

Use `container system property list` to show all properties that have set defaults:

```console
% bin/container system property ls
[build]
cpus = 2
memory = "2048mb"
rosetta = true
image = "ghcr.io/apple/container-builder-shim/builder:0.13.1"

[container]
cpus = 4
memory = "1gb"

[dns]
domain = "test"

[kernel]
binaryPath = "opt/kata/share/kata-containers/vmlinux-6.18.15-186"
url = "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst"
digest = "sha256:f63d54507d1f18635d94475077e4c2330de4d8e05cedf25f7c38f063b0e66a91"

[network]

[registry]
domain = "docker.io"

[vminit]
image = "ghcr.io/apple/containerization/vminit:0.34.0"
```

### Example: Disable Rosetta for builds

If you want to prevent the use of Rosetta translation during container builds on Apple Silicon Macs, set the following in `~/.config/container/config.toml`:

```toml
[build]
rosetta = false
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
