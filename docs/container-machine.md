# Container machine

Container machine provides a highly integrated Linux environment that works seamlessly on your Mac. Container machines are fast, lightweight and persistent. They are based on standard OCI images that can be built and shared. Host integrations such as automatic user and home directory sharing provide quick and easy access to your Linux environment no matter where you are in a terminal.

## Why container machines

Containers are typically modeled after an application. A container machine is modeled after a Linux environment. It runs the image's init system allowing you to register long running services or test your application under a process supervisor.
A container machine automatically maps your username and home directory into the Linux environment. Your repositories and dotfiles are available on both platforms. Use editors and tools directly on macOS simultaneously building and running your application inside of the Linux environment.

- **Edit on the Mac, build inside.** Your repo lives in `$HOME` on macOS and is mounted at `/Users/<username>` inside the container machine. Use your macOS editor or IDE; compile and run inside your container machine.
- **Use macOS-native tooling against Linux artifacts.** Profilers, screenshot tools, browsers, and GUI debuggers on your Mac all see the same files the container machine sees — there is no copy step between "I built it" and "I am inspecting it".
- **Real Linux services for testing.** Run a database or whatever your stack needs as a system service — `systemctl start postgresql` works on images with `systemd` installed.
- **One environment per target distro.** Create as many container machines as you have target distros — `alpine`, `ubuntu`, `debian`. Each has the same `$HOME` and the same dotfiles from your Mac. Quickly test your application in various distributions.

## Quickstart

```bash
container machine create alpine:latest --name dev
container machine run -n dev whoami       # your host username, not root
container machine run -n dev pwd          # /home/<you> — your Mac home dir, mounted in
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

## Bring your own container machine image

Any Linux image that includes `/sbin/init` works as a container machine. For example, this Dockerfile builds an Ubuntu 24.04 container machine image with `systemd` and common command-line tools:

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

By default, `container` runs a built-in setup script on first boot to provision the user described above. To use your own setup instead, add an executable script at `/etc/machine/create-user.sh` to the image. It runs once, as root, on first boot, with these variables set:

- `CONTAINER_GID`
- `CONTAINER_HOME`
- `CONTAINER_MACHINE_ID`
- `CONTAINER_UID`
- `CONTAINER_USER`
