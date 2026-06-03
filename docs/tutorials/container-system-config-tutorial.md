# Customize `container` default configuration values

> [!IMPORTANT]
> This file contains documentation for the CURRENT BRANCH. To find documentation for official releases, find the target release on the [Release Page](https://github.com/apple/container/releases) and click the tag corresponding to your release version.
>
> Example: [release 0.4.1 tag](https://github.com/apple/container/tree/0.4.1)

Take a guided tour of setting configurations for `container` CLI commands and services.

## Configuration sources

The `container` service loads values from these TOML files at startup, with first-match-wins precedence:

1. Your user file at `~/.config/container/config.toml`.
2. An optional file shipped with the `container` package install at `<installRoot>/etc/container/config.toml`.

Any key absent from both files falls back to a hardcoded default. For the full schema and defaults, see the [`config.toml` reference](../container-system-config.md).

## Create a custom user TOML configuration file

The `container` service reads your file once at startup, so restart the service whenever you want changes to take effect.

### Open or create your config file

Your editable config lives at `~/.config/container/config.toml`. Create it if it does not exist:

```bash
mkdir -p ~/.config/container
touch ~/.config/container/config.toml
```

### Set the values you want to customize

Open the file in the editor of your choice and add only the sections and keys you want to change. 

For this tutorial, increase the default CPU and memory limits used for each new container and set a DNS domain for resolving container IP addresses from the host. 

```toml
[container]
cpus = 8
memory = "4g"

[dns]
domain = "test"
```

Each top-level table maps directly to a section of [ContainerSystemConfig](../container-system-config.md). 

### Restart the `container` service

To make your edits take effect, stop and start the system:

```bash
container system stop
container system start
```

### Verify the values are loaded

Use `container system property list` (alias `ls`) to print the merged configuration that the `container` service is using. 

```console
% container system property list
[build]
cpus = 2
memory = "2048mb"
rosetta = true
image = "ghcr.io/apple/container-builder-shim/builder:0.11.0"

[container]
cpus = 8
memory = "4gb"

[dns]
domain = "test"

[kernel]
binaryPath = "opt/kata/share/kata-containers/vmlinux-6.18.15-186"
url = "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst"

[network]

[registry]
domain = "docker.io"

[vminit]
image = "ghcr.io/apple/containerization/vminit:0.32.2"
```

For machine-readable output, pass `--format json`:

```bash
container system property list --format json
```
