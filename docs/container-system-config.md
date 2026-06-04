# `config.toml` reference

> [!IMPORTANT]
> This file contains documentation for the CURRENT BRANCH. To find documentation for official releases, find the target release on the [Release Page](https://github.com/apple/container/releases) and click the tag corresponding to your release version.
>
> Example: [release 0.4.1 tag](https://github.com/apple/container/tree/0.4.1)

For a guided walk-through on setting default values, see [Container system config tutorial](./tutorials/container-system-config-tutorial.md). 

Source of truth: [`Sources/ContainerPersistence/ContainerSystemConfig.swift`](../Sources/ContainerPersistence/ContainerSystemConfig.swift). 

## Top-level schema

```toml
[build]      # builder VM resources and image
[container]  # default per-container resources
[dns]        # default DNS domain for DNS resolution on host
[kernel]     # guest kernel binary path and download URL
[network]    # default subnets for new networks
[registry]   # default registry domain
[vminit]     # default vminitd image to use
[plugin.<id>]  # zero or more plugin-scoped sections
```

All top-level sections are optional. Omitted sections fall back to their defaults wholesale.

## `[build]`

Resources and image used for the builder VM that runs `container build`.

| Key       | Type        | Default                                              | Description                                                                 |
|-----------|-------------|------------------------------------------------------|-----------------------------------------------------------------------------|
| `rosetta` | `Bool`      | `true`                                               | Whether the builder VM uses Rosetta translation for non-native architectures. |
| `cpus`    | `Int`       | `2`                                                  | CPU count for the builder VM.                                              |
| `memory`  | [MemorySize](#memorysize-format)  | `"2048mb"`                                           | RAM allocation for the builder VM. |
| `image`   | `String`    | `ghcr.io/apple/container-builder-shim/builder:<tag>` | Reference for the builder image. The tag segment is taken from the project's bundled `container-builder-shim` version. |

## `[container]`

Defaults applied when `container run` / `container create` is invoked without `--cpus` or `--memory`.

| Key      | Type       | Default | Description                                                                |
|----------|------------|---------|----------------------------------------------------------------------------|
| `cpus`   | `Int`      | `4`     | Default CPU count per container.                                           |
| `memory` | [MemorySize](#memorysize-format) | `"1g"`  | Default RAM per container. |

## `[dns]`

| Key      | Type      | Default | Description                                                                |
|----------|-----------|---------|----------------------------------------------------------------------------|
| `domain` | `String?` | unset   | Local DNS domain appended to container hostnames (e.g. `"test"` makes `my-web-server` resolvable as `my-web-server.test`). When unset, no domain is appended. |

## `[kernel]`

Guest kernel used when launching container VMs. Defaults change per release as kernels are bumped — check the [source](../Sources/ContainerPersistence/ContainerSystemConfig.swift) for current values.

| Key          | Type     | Default                                                                                                | Description                                                                  |
|--------------|----------|--------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------|
| `binaryPath` | `String` | `"opt/kata/share/kata-containers/vmlinux-6.18.15-186"`                                                 | Path **inside** the downloaded kernel archive that points to the kernel binary. |
| `url`        | `URL`    | `"https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst"` | Archive to download when no kernel is installed. Encoded and decoded as a plain string in TOML. |

## `[network]`

Default subnets used when creating networks without explicit `--subnet` / `--subnet-v6` flags.

| Key        | Type       | Default | Description                                                                                       |
|------------|------------|---------|---------------------------------------------------------------------------------------------------|
| `subnet`   | [CIDRv4?](#cidrv4--cidrv6)  | unset   | IPv4 CIDR (e.g. `"192.168.100.0/24"`). When unset, the system auto-allocates a non-overlapping subnet. |
| `subnetv6` | [CIDRv6?](#cidrv4--cidrv6)  | unset   | IPv6 CIDR (e.g. `"fd00:abcd::/64"`). When unset, the system auto-allocates.                       |

## `[registry]`

| Key      | Type     | Default      | Description                                                                                                  |
|----------|----------|--------------|--------------------------------------------------------------------------------------------------------------|
| `domain` | `String` | `"docker.io"` | Registry assumed when an image reference omits the registry host (e.g. `alpine` → `docker.io/library/alpine`). |

## `[vminit]`

| Key     | Type     | Default                                                | Description                                                                                              |
|---------|----------|--------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| `image` | `String` | `ghcr.io/apple/containerization/vminit:<tag>`     | Reference for the `vminitd` image used to boot container VMs. The tag segment is taken from the project's bundled `containerization` version.  |

## `[plugin.<id>]`

Plugins can ship their own configuration schemas under `[plugin.<id>]`, where `<id>` is the plugin's identifier. Each plugin defines and reads its own section — values under one plugin's section cannot leak into another's. Consult the documentation for the specific plugin you want to configure.

| Key                | Type     | Notes                                                                                       |
|--------------------|----------|---------------------------------------------------------------------------------------------|
| `<plugin-defined>` | varies   | Schema is defined by the plugin. TODO: Add tutorial on setting plugin specific values. |

## Type formats

### MemorySize format

Quoted string with a numeric prefix and a binary unit suffix. Parsing is case-insensitive; the suffix may be one of:

| Suffix family       | Unit                     | Example values         |
|---------------------|--------------------------|------------------------|
| `b`                 | bytes                    | `"1024b"`              |
| `k`, `kb`, `kib`    | kibibytes (1024 bytes)   | `"512k"`, `"512kb"`    |
| `m`, `mb`, `mib`    | mebibytes (1024 KiB)     | `"2048mb"`             |
| `g`, `gb`, `gib`    | gibibytes (1024 MiB)     | `"4g"`, `"4gb"`        |
| `t`, `tb`, `tib`    | tebibytes                | `"1t"`                 |
| `p`, `pb`, `pib`    | pebibytes                | `"1p"`                 |

All units are **binary** (powers of 1024), even when written with `kb`/`mb`/`gb`. The encoded form uses lowercase suffix `b`/`kb`/`mb`/`gb`/`tb`/`pb`, e.g. a value parsed from `"2g"` is emitted as `"2gb"`.

A bare integer (e.g. `"2048"`) parses as bytes.

Source: [`Sources/ContainerPersistence/Measurement+Parse.swift`](../Sources/ContainerPersistence/Measurement+Parse.swift).

### `CIDRv4` / `CIDRv6`

Quoted string. IPv4 example: `"192.168.100.0/24"`. IPv6 example: `"fd00:abcd::/64"`. The loader rejects invalid CIDR strings at decode time.
