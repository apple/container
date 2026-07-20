# How-to

> [!IMPORTANT]
> This file contains documentation for the CURRENT BRANCH. To find documentation for official releases, find the target release on the [Release Page](https://github.com/apple/container/releases) and click the tag corresponding to your release version. 
>
> Example: [release 0.4.1 tag](https://github.com/apple/container/tree/0.4.1)

`container` has a lot of surface area beyond the [basic tutorial](./tutorials/start-here.md). Each topic below has its own guide — pick the one that matches what you're trying to do.

## Topics

- [Resource usage](./resource-usage.md) — CPU and memory limits for containers and builds, overcommitting resources, monitoring usage with `container stats`, and reclaiming disk space.
- [Mounts and volumes](./volumes.md) — bind-mount host directories, create named volumes, and mount temporary tmpfs storage.
- [Networking](./networking.md) — DNS-based container names, container-to-container connectivity, port forwarding, custom MAC addresses, and isolated networks.
- [Host integration](./host-integration.md) — forward your SSH agent into a container, and reach a service running on your Mac from inside a container.
- [Resource limits (ulimits)](./ulimits.md) — per-process limits like open-file and process-count limits.
- [Runtime configuration](./runtime-configuration.md) — Linux capabilities, masked and read-only paths, nested virtualization, and customizing the container's init process.
- [Multiplatform images](./multiplatform-images.md) — build, run, and publish images that support both Apple silicon and x86-64.
- [Inspecting containers and images](./container-inspection.md) — machine-readable `inspect` and `list` output for scripting.
- [Logs](./logs.md) — container output, VM boot logs, and the `container` system's own logs.
- [`config.toml` reference](./container-system-config.md) — every configuration key, its default, and how to view your merged configuration.
- Container machines — persistent Linux environments built from OCI images, with your home directory mounted in and the filesystem surviving stop/start. See [container-machine.md](./container-machine.md) for the full guide.
- [Shell completions](./shell-completions.md) — generate and install completion scripts for `zsh`, `bash`, and `fish`.
