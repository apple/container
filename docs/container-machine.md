# Container machine

Container machine provides a highly integrated Linux environment that works seamlessly on your Mac. Container machines are fast, lightweight and persistent. They're based on standard OCI images you can build and share. A container machine has seamless access to macOS home directory – if you're anywhere under your home directory and you open a shell session in a container machine, the Linux session starts in that same directory, with your same username and file access permissions.

> [!WARNING]
> Running an image as a container machine is much closer to running a macOS program directly on your host than to running a regular container. A container machine trades away much of the isolation that makes a regular Apple container safer for running untrusted code. Only create container machines from images you trust.
>
> A container machine image supplies its own `/sbin/init` that serves as the entry point for the machine, running as the OS init process (PID 1). That process, and everything it chooses to start afterward (services, cron jobs, and anything else), can do anything a Linux process running as root can do — with access to more of your host system. A container machine:
>
> - Automatically mounts your macOS home directory into the guest **read-write, at the same path**. Anything running in your container machine has access, with your macOS user permissions, to your repos, dotfiles, and anything else under `${HOME}`. Equivalent to `container create -v "${HOME}:${HOME}"`.
> - Forwards your host `SSH_AUTH_SOCK` into the guest, so anything running in the machine can use your ssh-agent to act as you (e.g. for `git`/`ssh` operations). Equivalent to `container create --ssh`.
> - Runs with **all Linux capabilities added** and **no masked or read-only `/proc`/`/sys` paths** — a container machine deliberately bypasses the default access controls that a regular container receives, since the image's init system needs to behave like a full Linux install. Equivalent to `container create --cap-add ALL --masked-path NONE --read-only-path NONE`.
> - Creates a guest account and Linux home directory, and configures **passwordless sudo** (`NOPASSWD:ALL`), mapped to your host UID/GID. Root inside the container machine can write anywhere in your mounted home directory with your macOS user permissions.

## Why container machines

Containers are typically modeled after an application. A container machine is modeled after a complete Linux environment. It runs the image's init system, so you can register long-running services or test your application under a process supervisor. It also maps your macOS username and home directory into the Linux environment. Your repositories and dotfiles are available on both platforms, so that you can:

- **Edit on the Mac, build inside.** Your repo lives in `$HOME` on macOS and is mounted at `/Users/<username>` inside the container machine. Use your macOS editor or IDE; compile and run inside your container machine.
- **Use macOS-native tooling against Linux artifacts.** Profilers, screenshot tools, browsers, and GUI debuggers on your Mac all see the same files the container machine sees — there is no copy step between "I built it" and "I am inspecting it".
- **Real Linux services for testing.** Run a database or whatever your stack needs as a system service — `systemctl start postgresql` works on images with `systemd` installed.
- **One environment per target distro.** Create as many container machines as you have target distros — `alpine`, `ubuntu`, `debian`. Each has the same `$HOME` and the same dotfiles from your Mac. Quickly test your application in various distributions.

## Quickstart

```bash
container machine create alpine:latest --name dev
container machine run -n dev whoami       # your host username, not root
container machine run -n dev pwd          # your host current directory if you're under it; otherwise the Linux user home directory
container machine run -n dev              # interactive shell; cd into your repos in $HOME
```

`container machine run` is how you get a shell or run a single command. If the container machine is stopped, `run` boots it first.

## Working in a container machine

### Open a shell, or run a single command

With no command, `container machine run` opens an interactive shell as a user that matches your host account:

```bash
container machine run -n dev
```

Pass a command to run it once and exit:

```bash
container machine run -n dev uname -a
container machine run -n dev -- cat /proc/cpuinfo
```

When you run `container machine run` anywhere under your macOS home directory, the Linux process runs in the equivalent directory in the container machine's home mount. Otherwise, the process runs in the your Linux user's home directory.

### Set a default

Pick a default container machine so you can drop the `-n` flag:

```bash
container machine set-default dev
container machine run                 # operates on dev
```

### List, inspect, stop, delete

```bash
container machine ls                  # list all container machines
container machine inspect dev         # JSON detail for one
container machine stop dev            # stop the container machine
container machine rm dev              # delete, including its persistent storage
```

`container machine` has the alias `m`, so `m ls`, `m run`, etc. all work.

### Resize CPUs, memory, or change the home-mount

`container machine set` updates configuration on disk. Changes take effect after the next stop and start:

```bash
container machine set -n dev cpus=4 memory=8G
container machine stop dev
container machine run -n dev -- nproc
```

Memory defaults to half of host memory. The home-mount can be `rw` (default), `ro`, or `none`.

### Nested virtualization and custom kernels

A container machine supports nested virtualization. The requirements for this to work are:

1. Apple Silicon **M3 or later** with **macOS 15 or later**.
2. A Linux kernel with CONFIG_KVM=y enabled. The default kernel does not support this.

```bash
container machine create \
    --virtualization \
    --kernel /path/to/vmlinux-kvm \
    --name kvm-dev \
    alpine:latest

# Verify /dev/kvm is exposed:
container machine run -n kvm-dev -- ls -l /dev/kvm
```

Options can be toggled on an existing container machine.

```bash
container machine set -n dev virtualization=true kernel=/path/to/vmlinux-kvm
container machine stop dev
container machine run -n dev -- ls -l /dev/kvm

# reset to the default kernel
container machine set -n dev kernel=
```

## Bring your own image

Any Linux image that includes `/sbin/init` works as a container machine. Beyond that, the built-in user setup described below needs a few common tools already present in most general-purpose distro images — setup fails if any of these are missing:

- A POSIX shell at `/bin/sh` (busybox's `ash`/`dash`, or `bash`, both work) — what the setup script itself runs as.
- `getent`, to check for existing accounts/groups by uid, gid, or name.
- `date` with `%s` support (seconds since epoch), to timestamp the new account.
- `chown`, `mkdir`, `cp`, and `tr` — standard coreutils/busybox utilities.

Setup also always writes a passwordless-sudo grant to `/etc/sudoers.d/<user>`, but that's just a file — it does nothing unless `sudo` is installed and configured to read `/etc/sudoers.d/` (the default on virtually every distro). If `sudo` is missing, setup still succeeds; the grant is simply inert.

For example, this Dockerfile builds an Ubuntu 24.04 container machine image with `systemd` and common command-line tools (including `sudo`, so the passwordless-sudo grant actually works):

```dockerfile
FROM ubuntu:24.04

ENV container container

RUN apt-get update && \
    apt-get install -y \
    dbus systemd openssh-server net-tools iproute2 iputils-ping curl wget vim-tiny man sudo && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    yes | unminimize

RUN >/etc/machine-id
RUN >/var/lib/dbus/machine-id

RUN systemctl set-default multi-user.target
RUN systemctl mask \
      dev-hugepages.mount \
      sys-fs-fuse-connections.mount \
      systemd-update-utmp.service \
      systemd-tmpfiles-setup.service \
      console-getty.service
RUN systemctl disable \
      networkd-dispatcher.service

RUN sed -i -e 's/^AcceptEnv LANG LC_\*$/#AcceptEnv LANG LC_*/' /etc/ssh/sshd_config
```

Build it and create a container machine from it:

```bash
container build -t local/ubuntu-machine:latest .
container machine create local/ubuntu-machine:latest --name ubuntu
```

On every boot, `container` provisions the container machine user by directly editing `/etc/passwd`, `/etc/group`, and `/etc/shadow` — no distro-specific tooling (`useradd`, `adduser`, etc.) required. This is idempotent and safe to re-run: it's a no-op for anything that already exists, and it reapplies passwordless sudo access each time in case anything in the image removed it.

By default the account matches your host user (username, uid, gid, and home directory `/home/<user>`). Override any of these at creation time:

```bash
container machine create --user devuser --uid 1500 --gid 1600 --home /srv/devhome alpine:latest --name dev
```

`--user` accepts the format `name|uid[:gid]` (i.e. `name`, `uid`, `name:gid`, or `uid:gid` — the group must be numeric, since there's no existing account to resolve a group name against). `--uid`/`--gid` set the pieces `--user` didn't specify; any piece left fully unset falls back to the host user's.
