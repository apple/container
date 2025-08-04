# Container CLI Command Reference

## Core Commands

### `container run`

Runs a container from an image. If a command is provided, it will execute inside the container; otherwise the image's default command runs. By default the container runs in the foreground and STDIN remains closed unless `-i`/`--interactive` is specified.

**Usage**

```bash
container run [OPTIONS] IMAGE [COMMAND] [ARG...]
```

**Options**

*   **Resource management**
    *   `-c, --cpus <number>`: number of CPUs to allocate
    *   `-m, --memory <size>`: memory limit (K/M/G suffixes)
*   **Process control**
    *   `-e, --env <key=value>`: set environment variables
    *   `--env-file <file>`: read environment variables from a file
    *   `-i, --interactive`: keep STDIN open for interactive processes
    *   `-t, --tty`: allocate a pseudo-TTY
    *   `-u, --user <user>`: run as the specified user name or UID
    *   `--uid <uid>`: run as the specified numeric user ID
    *   `--gid <gid>`: run as the specified numeric group ID
    *   `--cwd <path>`: set the working directory inside the container
*   **Container management**
    *   `--name <name>`: assign a name to the container
    *   `-d, --detach`: run the container in the background (daemon mode)
    *   `--rm`: automatically remove the container when it exits
    *   `--cidfile <file>`: write the container ID to a file
*   **Registry**
    *   `--scheme <scheme>`: registry scheme (`auto`, `http`, or `https-`)
*   **Progress**
    *   `--disable-progress-updates`: disable progress display for image pulls and pushes
*   **Global**
    *   `--debug`: enable debug logging
    *   `-h, --help`: show help

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
container build [OPTIONS] PATH
```

**Options**

*   **Resource management**
    *   `-c, --cpus <number>`: CPUs to allocate to the build process (default 2)
    *   `-m, --memory <size>`: memory for the build process (default 2048MB)
*   **Build configuration**
    *   `--build-arg <key=value>`: build-time variables passed to the Dockerfile
    *   `-f, --file <path>`: path to the Dockerfile (default `Dockerfile`)
    *   `-l, --label <key=value>`: add metadata labels to the image
    *   `--no-cache`: disable cache usage
    *   `-o, --output <config>`: specify build output (default `type=oci`)
    *   `--arch <arch>`: target architecture (default `arm64`)
    *   `--os <os>`: target operating system (default `linux`)
    *   `--progress <type>`: progress output mode: `auto`, `plain`, or `tty`
    *   `--vsock-port <port>`: vsock port used by BuildKit (default 8088)
    *   `-t, --tag <name>`: set image name and tag
    *   `--target <stage>`: set the target stage for multi-stage builds
    *   `-q, --quiet`: suppress build output
*   **Hidden options**
    *   `--cache-in <config>`: configure build cache imports
    *   `--cache-out <config>`: configure build cache exports
*   **Global**
    *   `--debug`: enable debug logging
    *   `-h, --help`: show help

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

Starts one or more stopped containers. You can attach to the container's output streams and optionally keep STDIN open.

**Usage**

```bash
container start [OPTIONS] CONTAINER...
```

**Options**

*   `-a, --attach`: attach to STDOUT/STDERR of the container(s)
*   `-i, --interactive`: attach STDIN for interactive sessions
*   **Global**: `--debug`, `-h`/`--help`

### `container stop`

Stops running containers gracefully by sending a signal. A timeout can be specified before a SIGKILL is issued. If no containers are specified, nothing is stopped unless `--all` is used.

**Usage**

```bash
container stop [OPTIONS] [CONTAINER...]
```

**Options**

*   `-a, --all`: stop all running containers
*   `-s, --signal <signal>`: signal to send (default SIGTERM)
*   `-t, --time <seconds>`: timeout in seconds before killing the container (default 5)
*   **Global**: `--debug`, `-h`/`--help`

### `container kill`

Immediately kills running containers by sending a signal (defaults to `SIGKILL`). Use with caution: it does not allow for graceful shutdown.

**Usage**

```bash
container kill [OPTIONS] [CONTAINER...]
```

**Options**

*   `-s, --signal <signal>`: signal to send (default `KILL`)
*   `-a, --all`: kill all running containers
*   **Global**: `--debug`, `-h`/`--help`

### `container delete (rm)`

Removes one or more containers. If the container is running, you may force deletion with `--force`. Without a container ID, nothing happens unless `--all` is supplied.

**Usage**

```bash
container delete [OPTIONS] [CONTAINER...]
```

**Options**

*   `-f, --force`: remove running containers by sending SIGKILL
*   `-a, --all`: remove all containers
*   **Global**: `--debug`, `-h`/`--help`

### `container list (ls)`

Lists containers. By default only running containers are shown. Output can be formatted as a table or JSON.

**Usage**

```bash
container list [OPTIONS]
```

**Options**

*   `-a, --all`: include stopped containers
*   `-q, --quiet`: display only container IDs
*   `--format <format>`: output format: `table` or `json` (default `table`)
*   **Global**: `--debug`, `-h`/`--help`

### `container exec`

Executes a command inside a running container. It uses the same process flags as `container run` to control environment, user, and TTY settings.

**Usage**

```bash
container exec [OPTIONS] CONTAINER COMMAND [ARG...]
```

**Key flags**

*   `-e, --env <key=value>`: set environment variables inside the exec session
*   `--env-file <file>`: read environment variables from a file
*   `-i, --interactive`: keep STDIN open
*   `-t, --tty`: allocate a TTY
*   `-u, --user <user>`: run as a specific user
*   `--uid <uid>`, `--gid <gid>`: specify numeric UID/GID
*   `--cwd <path>`: set working directory
*   **Global**: `--debug`, `-h`/`--help`

### `container logs`

Fetches logs from a container. You can tail the logs (`-f`/`--follow`), restrict the number of lines shown, or view boot logs.

**Usage**

```bash
container logs [OPTIONS] CONTAINER
```

**Options**

*   `-f, --follow`: follow the log output for real-time streaming
*   `--boot`: show the container's boot logs instead of STDOUT/STDERR
*   `-n <lines>`: number of lines from the end of logs to display
*   **Global**: `--debug`, `-h`/`--help`

### `container inspect`

Displays detailed container information in JSON. Pass one or more container IDs to inspect multiple containers.

**Usage**

```bash
container inspect [OPTIONS] CONTAINER...
```

No additional flags; uses global flags for debug and help.

## Image Management

### `container image list (ls)`

Lists local images. Verbose output provides additional details such as image ID, creation time and size; JSON output provides the same data in machine-readable form.

**Usage**

```bash
container image list [OPTIONS]
```

**Options**

*   `-q, --quiet`: show only image names
*   `-v, --verbose`: produce verbose listing
*   `--format <format>`: `table` (default) or `json`
*   **Global**: `--debug`, `-h`/`--help`

### `container image pull`

Pulls an image from a registry. Supports specifying a platform and controlling progress display.

**Usage**

```bash
container image pull [OPTIONS] REFERENCE
```

**Options**

*   `--platform <platform>`: specific platform to pull (e.g., `linux/arm64/v8`)
*   `--scheme <scheme>`: registry scheme (`auto`, `http`, `https`)
*   `--disable-progress-updates`: disable progress display
*   **Global**: `--debug`, `-h`/`--help`

### `container image push`

Pushes an image to a registry. The flags mirror those for `image pull` with the addition of specifying a platform for multi-platform images.

**Usage**

```bash
container image push [OPTIONS] REFERENCE
```

**Options**

*   `--platform <platform>`: platform to push (defaults to all available)
*   `--scheme <scheme>`: registry scheme
*   `--disable-progress-updates`: disable progress display
*   **Global**: `--debug`, `-h`/`--help`

### `container image save`

Saves an image to a tar archive on disk. Useful for exporting images for offline transport.

**Usage**

```bash
container image save [OPTIONS] REFERENCE
```

**Options**

*   `--platform <platform>`: platform variant to save (optional)
*   `-o, --output <file>`: path to the output tar file (required)
*   **Global**: `--debug`, `-h`/`--help`

### `container image load`

Loads images from a tar archive created by `image save`. The tar file must be specified via `--input`.

**Usage**

```bash
container image load [OPTIONS]
```

**Options**

*   `-i, --input <file>`: path to the tar archive to load (required)
*   **Global**: `--debug`, `-h`/`--help`

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
*   **Global**: `--debug`, `-h`/`--help`

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

Only global flags (`--debug`, `-h`/`--help`) are available.

## Builder Management

The builder commands manage the BuildKit instance used for image builds. These commands are available when the system supports BuildKit.

### `container builder start`

Starts the BuildKit builder container. CPU and memory limits can be set for the builder.

**Usage**

```bash
container builder start [OPTIONS]
```

**Options**

*   `-c, --cpus <number>`: number of CPUs allocated to the builder (default 2)
*   `-m, --memory <size>`: memory allocated to the builder (default 2048MB)
*   **Global**: `--debug`, `-h`/`--help`

### `container builder status`

Shows the current status of the BuildKit builder. Without flags a human-readable table is displayed; with `--json` the status is returned as JSON.

**Usage**

```bash
container builder status [OPTIONS]
```

**Options**

*   `--json`: output status as JSON
*   **Global**: `--debug`, `-h`/`--help`

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
*   **Global**: `--debug`, `-h`/`--help`

## Network Management (macOS 26 +)

The network commands are available on macOS 26 and later and allow creation and management of user-defined container networks.

### `container network create`

Creates a new network with the given name.

**Usage**

```bash
container network create NAME
```

No additional flags; uses global options for debugging and help.

### `container network delete (rm)`

Deletes one or more networks. When deleting multiple networks, pass them as separate arguments. To delete all networks, use `--all`.

**Usage**

```bash
container network delete [OPTIONS] [NAME...]
```

**Options**

*   `-a, --all`: delete all defined networks
*   **Global**: `--debug`, `-h`/`--help`

### `container network list (ls)`

Lists user-defined networks.

**Usage**

```bash
container network list [OPTIONS]
```

**Options**

*   `-q, --quiet`: show only network IDs
*   `--format <format>`: output format (`table` or `json`)
*   **Global**: `--debug`, `-h`/`--help`

### `container network inspect`

Shows detailed information about one or more networks.

**Usage**

```bash
container network inspect [OPTIONS] NAME...
```

Only global flags are available for debugging and help.

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
*   `--scheme <scheme>`: registry scheme (`auto`, `http`, `https`)
*   **Global**: `--debug`, `-h`/`--help`

### `container registry logout`

Logs out of a registry, removing stored credentials.

**Usage**

```bash
container registry logout [OPTIONS] [SERVER]
```

No additional flags; uses global options for debugging and help.

### `container registry default` commands

The `registry default` group allows setting, unsetting, and inspecting the default registry used when no registry is specified on image references.

*   `container registry default set [OPTIONS] HOST`: Set the default registry.
    *   `--scheme <scheme>`: registry scheme (`auto`, `http`, `https`)
*   `container registry default unset (clear)`: Clears the default registry configuration.
*   `container registry default inspect`: Displays the current default registry, if any.

## System Management

System commands manage the container apiserver, logs, DNS settings and kernel. These are primarily for macOS hosts.

### `container system start`

Starts the container services and (optionally) installs a default kernel. It will start the `container-apiserver` and background services.

**Usage**

```bash
container system start [OPTIONS]
```

**Options**

*   `-p, --path <path>`: path to the `container-apiserver` binary
*   `--debug`: enable debug logging for the daemon
*   `--kernel-install`: install the default kernel (prompt if unset)
*   `--enable-kernel-install`: force kernel installation even if already installed
*   `--disable-kernel-install`: skip kernel installation

### `container system stop`

Stops the container services and deregisters them from launchd. You can specify a prefix to target services created with a different launchd prefix.

**Usage**

```bash
container system stop [OPTIONS]
```

**Options**

*   `-p, --prefix <prefix>`: launchd prefix (default: `com.apple.container.`)
*   **Global**: `--debug`, `-h`/`--help`

### `container system status`

Checks whether the container services are running and prints status information. It will ping the apiserver and report readiness.

**Usage**

```bash
container system status [OPTIONS]
```

**Options**

*   `-p, --prefix <prefix>`: launchd prefix to query (default: `com.apple.container.`)
*   **Global**: `--debug`, `-h`/`--help`

### `container system logs`

Displays logs from the container services. You can specify a time interval or follow new logs in real time.

**Usage**

```bash
container system logs [OPTIONS]
```

**Options**

*   `--last <duration>`: show logs for the given duration (e.g., `1h`, `30m`)
*   `-f, --follow`: stream logs as they are generated
*   **Global**: `--debug`, `-h`/`--help`

### DNS management (`container system dns`)

Commands for managing local DNS configurations used by containers. Available on macOS hosts.

*   `container system dns create NAME`: Create a new DNS configuration by specifying a domain name.
*   `container system dns delete (rm) NAME`: Delete an existing DNS configuration.
*   `container system dns list (ls)`: List all configured DNS domains for containers.
*   `container system dns default` commands: Manage the default DNS domain. This sub-group contains `set`, `unset`, and `inspect` commands.

### Kernel management (`container system kernel`)

Commands for managing the Linux kernel used by the container runtime on macOS hosts.

*   `container system kernel set [OPTIONS]`: Install or update the kernel.
    *   `--binary <path>`: path to a kernel binary (can be used with `--tar` inside a tar archive)
    *   `--tar <path | URL>`: path or URL to a tarball containing kernel images
    *   `--arch <arch>`: target architecture (`arm64` or `x86_64`)
    *   `--recommended`: download and install the recommended default kernel for your host
    *   **Global**: `--debug`, `-h`/`--help`

***

Command availability may vary depending on host operating system and macOS version.
