# Container CLI Command Reference

Note: Command availability may vary depending on host operating system and macOS version.

## Core Commands

### `container run`

Runs a container from an image. If a command is provided, it will execute inside the container; otherwise the image's default command runs. By default the container runs in the foreground and STDIN remains closed unless `-i`/`--interactive` is specified.

**Usage**

```bash
container run [OPTIONS] IMAGE [COMMAND] [ARG...]
```

**Options**

*   **Process options**
    *   `-e, --env <env>`: Set environment variables (format: key=value)
    *   `--env-file <env-file>`: Read in a file of environment variables (key=value format, ignores # comments and blank lines)
    *   `--gid <gid>`: Set the group ID for the process
    *   `-i, --interactive`: Keep the standard input open even if not attached
    *   `-t, --tty`: Open a TTY with the process
    *   `-u, --user <user>`: Set the user for the process (format: name|uid[:gid])
    *   `--uid <uid>`: Set the user ID for the process
    *   `-w, --workdir, --cwd <dir>`: Set the initial working directory inside the container
*   **Resource options**
    *   `-c, --cpus <cpus>`: Number of CPUs to allocate to the container
    *   `-m, --memory <memory>`: Amount of memory (1MiByte granularity), with optional K, M, G, T, or P suffix
*   **Management options**
    *   `-a, --arch <arch>`: Set arch if image can target multiple architectures (default: arm64)
    *   `--cidfile <cidfile>`: Write the container ID to the path provided
    *   `-d, --detach`: Run the container and detach from the process
    *   `--dns <ip>`: DNS nameserver IP address
    *   `--dns-domain <domain>`: Default DNS domain
    *   `--dns-option <option>`: DNS options
    *   `--dns-search <domain>`: DNS search domains
    *   `--entrypoint <cmd>`: Override the entrypoint of the image
    *   `-k, --kernel <path>`: Set a custom kernel path
    *   `-l, --label <label>`: Add a key=value label to the container
    *   `--mount <mount>`: Add a mount to the container (format: type=<>,source=<>,target=<>,readonly)
    *   `--name <name>`: Use the specified name as the container ID
    *   `--network <network>`: Attach the container to a network
    *   `--no-dns`: Do not configure DNS in the container
    *   `--os <os>`: Set OS if image can target multiple operating systems (default: linux)
    *   `-p, --publish <spec>`: Publish a port from container to host (format: [host-ip:]host-port:container-port[/protocol])
    *   `--platform <platform>`: Platform for the image if it's multi-platform. This takes precedence over --os and --arch
    *   `--publish-socket <spec>`: Publish a socket from container to host (format: host_path:container_path)
    *   `--rm, --remove`: Remove the container after it stops
    *   `--ssh`: Forward SSH agent socket to container
    *   `--tmpfs <tmpfs>`: Add a tmpfs mount to the container at the given path
    *   `-v, --volume <volume>`: Bind mount a volume into the container
    *   `--virtualization`: Expose virtualization capabilities to the container (requires host and guest support)
*   **Registry options**
    *   `--scheme <scheme>`: Scheme to use when connecting to the container registry. One of (http, https, auto) (default: auto)
*   **Progress options**
    *   `--disable-progress-updates`: Disable progress bar updates
*   **Global options**
    *   `--debug`: Enable debug output [environment: CONTAINER_DEBUG]
    *   `--version`: Show the version.
    *   `-h, --help`: Show help information.

**Examples**

```bash
# run a container and attach an interactive shell
container run -it ubuntu:latest /bin/bash

# run a background web server
container run -d --name web -p 8080:80 nginx:latest

# set environment variables and limit resources
container run -e NODE_ENV=production --cpus 2 --memory 1G node:18
```

### `container build`

Builds an OCI image from a local build context. It reads a Dockerfile (default `Dockerfile`) and produces an image tagged with `-t` option. The build runs in isolation using BuildKit, and resource limits may be set for the build process itself.

**Usage**

```bash
container build [OPTIONS] [CONTEXT-DIR]
```

**Arguments**

*   `CONTEXT-DIR`: Build directory (default: .)

**Options**

*   `-a, --arch <value>`: Add the architecture type to the build
*   `--build-arg <key=val>`: Set build-time variables
*   `-c, --cpus <cpus>`: Number of CPUs to allocate to the builder container (default: 2)
*   `-f, --file <path>`: Path to Dockerfile (default: Dockerfile)
*   `-l, --label <key=val>`: Set a label
*   `-m, --memory <memory>`: Amount of builder container memory (1MiByte granularity), with optional K, M, G, T, or P suffix (default: 2048MB)
*   `--no-cache`: Do not use cache
*   `-o, --output <value>`: Output configuration for the build (format: type=<oci|tar|local>[,dest=]) (default: type=oci)
*   `--os <value>`: Add the OS type to the build
*   `--platform <platform>`: Add the platform to the build (takes precedence over --os and --arch)
*   `--progress <type>`: Progress type (format: auto|plain|tty)] (default: auto)
*   `-q, --quiet`: Suppress build output
*   `-t, --tag <name>`: Name for the built image
*   `--target <stage>`: Set the target build stage
*   `--vsock-port <port>`: Builder shim vsock port (default: 8088)
*   `--version`: Show the version.
*   `-h, --help`: Show help information.

**Examples**

```bash
# build an image and tag it as my-app:latest
container build -t my-app:latest .

# use a custom Dockerfile
container build -f docker/Dockerfile.prod -t my-app:prod .

# pass build args
container build --build-arg NODE_VERSION=18 -t my-app .

# build the production stage only and disable cache
container build --target production --no-cache -t my-app:prod .
```

## Container Management

### `container create`

Creates a container from an image without starting it. This command accepts most of the same process/resource/management flags as `container run`, but leaves the container stopped after creation.

**Usage**

```bash
container create [OPTIONS] IMAGE [COMMAND] [ARG...]
```

**Typical use**: create a container to inspect or modify its configuration before running it.

### `container start`

Starts a stopped container. You can attach to the container's output streams and optionally keep STDIN open.

**Usage**

```bash
container start [OPTIONS] CONTAINER-ID
```

**Arguments**

*   `CONTAINER-ID`: Container ID

**Options**

*   `-a, --attach`: Attach STDOUT/STDERR
*   `-i, --interactive`: Attach STDIN
*   `--debug`: Enable debug output [environment: CONTAINER_DEBUG]
*   `--version`: Show the version.
*   `-h, --help`: Show help information.

### `container stop`

Stops running containers gracefully by sending a signal. A timeout can be specified before a SIGKILL is issued. If no containers are specified, nothing is stopped unless `--all` is used.

**Usage**

```bash
container stop [OPTIONS] [CONTAINER-IDS...]
```

**Arguments**

*   `CONTAINER-IDS`: Container IDs

**Options**

*   `-a, --all`: Stop all running containers
*   `-s, --signal <signal>`: Signal to send the containers (default: SIGTERM)
*   `-t, --time <time>`: Seconds to wait before killing the containers (default: 5)
*   `--debug`: Enable debug output [environment: CONTAINER_DEBUG]
*   `--version`: Show the version.
*   `-h, --help`: Show help information.

### `container kill`

Immediately kills running containers by sending a signal (defaults to `KILL`). Use with caution: it does not allow for graceful shutdown.

**Usage**

```bash
container kill [OPTIONS] [CONTAINER-IDS...]
```

**Arguments**

*   `CONTAINER-IDS`: Container IDs

**Options**

*   `-a, --all`: Kill or signal all running containers
*   `-s, --signal <signal>`: Signal to send to the container(s) (default: KILL)
*   `--debug`: Enable debug output [environment: CONTAINER_DEBUG]
*   `--version`: Show the version.
*   `-h, --help`: Show help information.

### `container delete (rm)`

Removes one or more containers. If the container is running, you may force deletion with `--force`. Without a container ID, nothing happens unless `--all` is supplied.

**Usage**

```bash
container delete [OPTIONS] [CONTAINER-IDS...]
```

**Arguments**

*   `CONTAINER-IDS`: Container IDs

**Options**

*   `-a, --all`: Remove all containers
*   `-f, --force`: Force the removal of one or more running containers
*   `--debug`: Enable debug output [environment: CONTAINER_DEBUG]
*   `--version`: Show the version.
*   `-h, --help`: Show help information.

### `container list (ls)`

Lists containers. By default only running containers are shown. Output can be formatted as a table or JSON.

**Usage**

```bash
container list [OPTIONS]
```

**Options**

*   `-a, --all`: Show stopped containers as well
*   `--format <format>`: Format of the output (values: json, table; default: table)
*   `-q, --quiet`: Only output the container ID
*   `--debug`: Enable debug output [environment: CONTAINER_DEBUG]
*   `--version`: Show the version.
*   `-h, --help`: Show help information.

### `container exec`

Executes a command inside a running container. It uses the same process flags as `container run` to control environment, user, and TTY settings.

**Usage**

```bash
container exec [OPTIONS] CONTAINER-ID ARGUMENTS...
```

**Arguments**

*   `CONTAINER-ID`: Container ID
*   `ARGUMENTS`: New process arguments

**Process flags**

*   `-e, --env <env>`: Set environment variables (format: key=value)
*   `--env-file <env-file>`: Read in a file of environment variables (key=value format, ignores # comments and blank lines)
*   `--gid <gid>`: Set the group ID for the process
*   `-i, --interactive`: Keep the standard input open even if not attached
*   `-t, --tty`: Open a TTY with the process
*   `-u, --user <user>`: Set the user for the process (format: name|uid[:gid])
*   `--uid <uid>`: Set the user ID for the process
*   `-w, --workdir, --cwd <dir>`: Set the initial working directory inside the container

**Options**

*   `--debug`: Enable debug output [environment: CONTAINER_DEBUG]
*   `--version`: Show the version.
*   `-h, --help`: Show help information.

### `container logs`

Fetches logs from a container. You can follow the logs (`-f`/`--follow`), restrict the number of lines shown, or view boot logs.

**Usage**

```bash
container logs [OPTIONS] CONTAINER-ID
```

**Arguments**

*   `CONTAINER-ID`: Container ID

**Options**

*   `--boot`: Display the boot log for the container instead of stdio
*   `-f, --follow`: Follow log output
*   `-n <n>`: Number of lines to show from the end of the logs. If not provided this will print all of the logs
*   `--debug`: Enable debug output [environment: CONTAINER_DEBUG]
*   `--version`: Show the version.
*   `-h, --help`: Show help information.

### `container inspect`

Displays detailed container information in JSON. Pass one or more container IDs to inspect multiple containers.

**Usage**

```bash
container inspect [OPTIONS] CONTAINER-IDS...
```

**Arguments**

*   `CONTAINER-IDS`: Container IDs

**Options**

*   `--debug`: Enable debug output [environment: CONTAINER_DEBUG]
*   `--version`: Show the version.
*   `-h, --help`: Show help information.

## Image Management

### `container image list (ls)`

Lists local images. Verbose output provides additional details such as image ID, creation time and size; JSON output provides the same data in machine-readable form.

**Usage**

```bash
container image list [OPTIONS]
```

**Options**

*   `-q, --quiet`: Only output the image name
*   `-v, --verbose`: Verbose output
*   `--format <format>`: Format of the output (values: `json`, `table`; default: `table`)
*   **Global**: `--debug`, `--version`, `-h`/`--help`

### `container image pull`

Pulls an image from a registry. Supports specifying a platform and controlling progress display.

**Usage**

```bash
container image pull [OPTIONS] REFERENCE
```

**Options**

*   `--platform <platform>`: Platform string in the form `os/arch/variant`. Example `linux/arm64/v8`, `linux/amd64`. Default: current host platform.
*   `--scheme <scheme>`: Scheme to use when connecting to the container registry. One of (`http`, `https`, `auto`) (default: `auto`)
*   `--disable-progress-updates`: Disable progress bar updates
*   **Global**: `--debug`, `--version`, `-h`/`--help`

### `container image push`

Pushes an image to a registry. The flags mirror those for `image pull` with the addition of specifying a platform for multi-platform images.

**Usage**

```bash
container image push [OPTIONS] REFERENCE
```

**Options**

*   `--platform <platform>`: Platform string in the form `os/arch/variant`. Example `linux/arm64/v8`, `linux/amd64` (optional)
*   `--scheme <scheme>`: Scheme to use when connecting to the container registry. One of (`http`, `https`, `auto`) (default: `auto`)
*   `--disable-progress-updates`: Disable progress bar updates
*   **Global**: `--debug`, `--version`, `-h`/`--help`

### `container image save`

Saves an image to a tar archive on disk. Useful for exporting images for offline transport.

**Usage**

```bash
container image save [OPTIONS] REFERENCE
```

**Options**

*   `--platform <platform>`: Platform string in the form `os/arch/variant`. Example `linux/arm64/v8`, `linux/amd64` (optional)
*   `-o, --output <file>`: Path to save the image tar archive
*   **Global**: `--debug`, `--version`, `-h`/`--help`

### `container image load`

Loads images from a tar archive created by `image save`. The tar file must be specified via `--input`.

**Usage**

```bash
container image load [OPTIONS]
```

**Options**

*   `-i, --input <file>`: Path to the tar archive to load images from
*   **Global**: `--debug`, `--version`, `-h`/`--help`

### `container image tag`

Applies a new tag to an existing image. The original image reference remains unchanged.

**Usage**

```bash
container image tag SOURCE_IMAGE[:TAG] TARGET_IMAGE[:TAG]
```

No extra flags aside from global options.

### `container image delete (rm)`

Removes one or more images. If no images are provided, `--all` can be used to remove all images. Images currently referenced by running containers cannot be deleted without first removing those containers.

**Usage**

```bash
container image delete [OPTIONS] [IMAGE...]
```

**Options**

*   `-a, --all`: remove all images
*   **Global**: `--debug`, `--version`, `-h`/`--help`

### `container image prune`

Removes unused (dangling) images to reclaim disk space. The command outputs the amount of space freed after deletion.

**Usage**

```bash
container image prune [OPTIONS]
```

No extra options; uses global flags for debug and help.

### `container image inspect`

Shows detailed information for one or more images in JSON format. Accepts image names or IDs.

**Usage**

```bash
container image inspect [OPTIONS] IMAGE...
```

Only global flags (`--debug`, `--version`, `-h`/`--help`) are available.

## Builder Management

The builder commands manage the BuildKit-based builder used for image builds.

### `container builder start`

Starts the BuildKit builder container. CPU and memory limits can be set for the builder.

**Usage**

```bash
container builder start [OPTIONS]
```

**Options**

*   `-c, --cpus <number>`: Number of CPUs to allocate to the container (default: 2)
*   `-m, --memory <size>`: Amount of memory in bytes, kilobytes (K), megabytes (M), or gigabytes (G) for the container, with MB granularity (for example, 1024K will result in 1MB being allocated for the container) (default: 2048MB)
*   **Global**: `--version`, `-h`/`--help`

### `container builder status`

Shows the current status of the BuildKit builder. Without flags a human-readable table is displayed; with `--json` the status is returned as JSON.

**Usage**

```bash
container builder status [OPTIONS]
```

**Options**

*   `--json`: output status as JSON
*   **Global**: `--version`, `-h`/`--help`

### `container builder stop`

Stops the BuildKit builder. No additional options are required; uses global flags only.

### `container builder delete (rm)`

Removes the BuildKit builder container. It can optionally force deletion if the builder is still running.

**Usage**

```bash
container builder delete [OPTIONS]
```

**Options**

*   `-f, --force`: force deletion even if the builder is running
*   **Global**: `--version`, `-h`/`--help`

## Network Management (macOS 26+)

The network commands are available on macOS 26 and later and allow creation and management of user-defined container networks.

### `container network create`

Creates a new network with the given name.

**Usage**

```bash
container network create NAME [OPTIONS]
```

**Options**

*   `--label <key=value>`: set metadata labels on the network
*   **Global**: `--version`, `-h`/`--help`

### `container network delete (rm)`

Deletes one or more networks. When deleting multiple networks, pass them as separate arguments. To delete all networks, use `--all`.

**Usage**

```bash
container network delete [OPTIONS] [NAME...]
```

**Options**

*   `-a, --all`: delete all defined networks
*   **Global**: `--debug`, `--version`, `-h`/`--help`

### `container network list (ls)`

Lists user-defined networks.

**Usage**

```bash
container network list [OPTIONS]
```

**Options**

*   `-q, --quiet`: Only output the network name
*   `--format <format>`: Format of the output (values: `json`, `table`; default: `table`)
*   **Global**: `--debug`, `--version`, `-h`/`--help`

### `container network inspect`

Shows detailed information about one or more networks.

**Usage**

```bash
container network inspect [OPTIONS] NAME...
```

Only global flags are available for debugging, version, and help.

## Volume Management

Manage persistent volumes for containers.

### `container volume create`

Creates a new volume with an optional size and driver-specific options.

**Usage**

```bash
container volume create [OPTIONS] NAME
```

**Options**

*   `-s <size>`: size of the volume (default: 512GB). Examples: `1G`, `512MB`, `2T`
*   `--opt <key=value>`: set driver-specific options
*   `--label <key=value>`: set metadata labels on the volume
*   **Global**: `--version`, `-h`/`--help`

### `container volume delete (rm)`

Removes one or more volumes by name.

**Usage**

```bash
container volume delete NAME...
```

Only global flags are available.

### `container volume list (ls)`

Lists volumes.

**Usage**

```bash
container volume list [OPTIONS]
```

**Options**

*   `-q, --quiet`: Only display volume names
*   `--format <format>`: Format of the output (values: `json`, `table`; default: `table`)
*   **Global**: `--version`, `-h`/`--help`

### `container volume inspect`

Displays detailed information for one or more volumes in JSON.

**Usage**

```bash
container volume inspect NAME...
```

Only global flags are available.

## Registry Management

The registry commands manage authentication and defaults for container registries.

### `container registry login`

Authenticates with a registry. Credentials can be provided interactively or via flags. The login is stored for reuse by subsequent commands.

**Usage**

```bash
container registry login [OPTIONS] SERVER
```

**Options**

*   `-u, --username <username>`: username for the registry
*   `--password-stdin`: read the password from STDIN (non-interactive)
*   `--scheme <scheme>`: registry scheme. One of (`http`, `https`, `auto`) (default: `auto`)
*   **Global**: `--version`, `-h`/`--help`

### `container registry logout`

Logs out of a registry, removing stored credentials.

**Usage**

```bash
container registry logout SERVER
```

Only `--version` and `-h`/`--help` are available.

## System Management

System commands manage the container apiserver, logs, DNS settings and kernel. These are only available on macOS hosts.

### `container system start`

Starts the container services and (optionally) installs a default kernel. It will start the `container-apiserver` and background services.

**Usage**

```bash
container system start [OPTIONS]
```

**Options**

*   `-a, --app-root <path>`: application data directory
*   `--install-root <path>`: path to the installation root directory
*   `--debug`: enable debug logging for the runtime daemon
*   `--enable-kernel-install`: install the recommended default kernel
*   `--disable-kernel-install`: skip installing the default kernel
  If neither kernel-install flag is provided, you will be prompted to choose whether to install the recommended kernel.

### `container system stop`

Stops the container services and deregisters them from launchd. You can specify a prefix to target services created with a different launchd prefix.

**Usage**

```bash
container system stop [OPTIONS]
```

**Options**

*   `-p, --prefix <prefix>`: launchd prefix (default: `com.apple.container.`)
*   **Global**: `--version`, `-h`/`--help`

### `container system status`

Checks whether the container services are running and prints status information. It will ping the apiserver and report readiness.

**Usage**

```bash
container system status [OPTIONS]
```

**Options**

*   `-p, --prefix <prefix>`: launchd prefix to query (default: `com.apple.container.`)
*   **Global**: `--version`, `-h`/`--help`

### `container system logs`

Displays logs from the container services. You can specify a time interval or follow new logs in real time.

**Usage**

```bash
container system logs [OPTIONS]
```

**Options**

*   `--last <duration>`: Fetch logs starting from the specified time period (minus the current time); supported formats: m, h, d (default: 5m)
*   `-f, --follow`: Follow log output
*   **Global**: `--debug`, `--version`, `-h`/`--help`

### `container system dns create`

Creates a local DNS domain for containers. Requires administrator privileges (use sudo).

**Usage**

```bash
container system dns create NAME
```

No options.

### `container system dns delete (rm)`

Deletes a local DNS domain. Requires administrator privileges (use sudo).

**Usage**

```bash
container system dns delete NAME
```

No options.

### `container system dns list (ls)`

Lists configured local DNS domains for containers.

**Usage**

```bash
container system dns list
```

No options.

### `container system kernel set`

Installs or updates the Linux kernel used by the container runtime on macOS hosts.

**Usage**

```bash
container system kernel set [OPTIONS]
```

**Options**

*   `--binary <path>`: Path to a kernel binary (can be used with `--tar` inside a tar archive)
*   `--tar <path | URL>`: Path or URL to a tarball containing kernel images
*   `--arch <arch>`: Target architecture (`arm64` or `x86_64`)
*   `--recommended`: Download and install the recommended default kernel for your host
*   **Global**: `--debug`, `--version`, `-h`/`--help`

### `container system property list (ls)`

Lists all available system properties with their current values, types, and descriptions. Output can be formatted as a table or JSON.

**Usage**

```bash
container system property list [OPTIONS]
```

**Options**

*   `-q, --quiet`: Only output the property IDs
*   `--format <format>`: Format of the output (values: `json`, `table`; default: `table`)
*   **Global**: `--debug`, `--version`, `-h`/`--help`

**Examples**

```bash
# list all properties in table format
container system property list

# get only property IDs
container system property list --quiet

# output as JSON for scripting
container system property list --format json
```

### `container system property get`

Retrieves the current value of a specific system property by its ID.

**Usage**

```bash
container system property get PROPERTY_ID
```

**Arguments**

*   `PROPERTY_ID`: The ID of the property to retrieve (use `property list` to see available IDs)

**Global flags**: `--debug`, `--version`, `-h`/`--help`

**Examples**

```bash
# get the default registry domain
container system property get registry.domain

# get the current DNS domain setting
container system property get dns.domain
```

### `container system property set`

Sets the value of a system property. The command validates the value based on the property type (boolean, domain name, image reference, URL, or CIDR address).

**Usage**

```bash
container system property set PROPERTY_ID VALUE
```

**Arguments**

*   `PROPERTY_ID`: The ID of the property to set
*   `VALUE`: The new value for the property

**Property Types and Validation**

*   **Boolean properties** (`build.rosetta`): Accepts `true`, `t`, `false`, `f` (case-insensitive)
*   **Domain properties** (`dns.domain`, `registry.domain`): Must be valid domain names
*   **Image properties** (`image.builder`, `image.init`): Must be valid OCI image references
*   **URL properties** (`kernel.url`): Must be valid URLs
*   **Network properties** (`network.subnet`): Must be valid CIDR addresses
*   **Path properties** (`kernel.binaryPath`): Accept any string value

**Global flags**: `--debug`, `--version`, `-h`/`--help`

**Examples**

```bash
# enable Rosetta for AMD64 builds on ARM64
container system property set build.rosetta true

# set a custom DNS domain
container system property set dns.domain mycompany.local

# configure a custom registry
container system property set registry.domain registry.example.com

# set a custom builder image
container system property set image.builder myregistry.com/custom-builder:latest
```

### `container system property clear`

Clears (unsets) a system property, reverting it to its default value.

**Usage**

```bash
container system property clear PROPERTY_ID
```

**Arguments**

*   `PROPERTY_ID`: The ID of the property to clear

**Global flags**: `--debug`, `--version`, `-h`/`--help`

**Examples**

```bash
# clear custom DNS domain (revert to default)
container system property clear dns.domain

# clear custom registry setting
container system property clear registry.domain
