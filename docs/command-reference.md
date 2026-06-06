# Container CLI Command Reference

> [!IMPORTANT]
> This file contains documentation for the CURRENT BRANCH. To find documentation for official releases, find the target release on the [Release Page](https://github.com/apple/container/releases) and click the tag corresponding to your release version. 
>
> Example: [release 0.4.1 tag](https://github.com/apple/container/tree/0.4.1)

Command availability may vary depending on your macOS version.

## Core Commands

### `container run`

Runs a container from an image. If a command is provided, it will execute inside the container; otherwise the image's default command runs. By default the container runs in the foreground and stdin remains closed unless `-i`/`--interactive` is specified.

**Usage**

```bash
container run [<options>] <image> [<arguments> ...]
```

**Arguments**

*   `<image>`: Image name
*   `<arguments>`: Container init process arguments

**Process Options**

*   `-e, --env <env>`: Set environment variables (format: key=value, or just key to inherit from host)
*   `--env-file <env-file>`: Read in a file of environment variables (key=value format, ignores # comments and blank lines)
*   `--gid <gid>`: Set the group ID for the process
*   `-i, --interactive`: Keep the standard input open even if not attached
*   `-t, --tty`: Open a TTY with the process
*   `-u, --user <user>`: Set the user for the process (format: name|uid[:gid])
*   `--uid <uid>`: Set the user ID for the process
*   `--ulimit <limit>`: Set resource limits (format: `<type>=<soft>[:<hard>]`)
*   `-w, --workdir, --cwd <dir>`: Set the initial working directory inside the container

**Resource Options**

*   `-c, --cpus <cpus>`: Number of CPUs to allocate to the container
*   `-m, --memory <memory>`: Amount of memory (1MiByte granularity), with optional K, M, G, T, or P suffix

**Management Options**

*   `-a, --arch <arch>`: Set arch if image can target multiple architectures (default: arm64)
*   `--cap-add <cap>`: Add a Linux capability (e.g. `CAP_NET_RAW`, `NET_RAW`, or `ALL`)
*   `--cap-drop <cap>`: Drop a Linux capability (e.g. `CAP_NET_RAW`, `NET_RAW`, or `ALL`)
*   `--cidfile <cidfile>`: Write the container ID to the path provided
*   `-d, --detach`: Run the container and detach from the process
*   `--dns <ip>`: DNS nameserver IP address
*   `--dns-domain <domain>`: Default DNS domain
*   `--dns-option <option>`: DNS options
*   `--dns-search <domain>`: DNS search domains
*   `--entrypoint <cmd>`: Override the entrypoint of the image
*   `--init`: Run an init process inside the container that forwards signals and reaps processes
*   `--init-image <image>`: Use a custom init image instead of the default. This allows customizing boot-time behavior before the OCI container starts, such as running VM-level daemons, configuring eBPF filters, or debugging the init process.
*   `-k, --kernel <path>`: Set a custom kernel path
*   `-l, --label <label>`: Add a key=value label to the container
*   `--mount <mount>`: Add a mount to the container (format: type=<>,source=<>,target=<>,readonly)
*   `--name <name>`: Use the specified name as the container ID
*   `--network <network>`: Attach the container to a network (format: `<name>[,mac=XX:XX:XX:XX:XX:XX][,mtu=VALUE]`)
*   `--no-dns`: Do not configure DNS in the container
*   `--os <os>`: Set OS if image can target multiple operating systems (default: linux)
*   `-p, --publish <spec>`: Publish a port from container to host (format: [host-ip:]host-port:container-port[/protocol])
*   `--platform <platform>`: Platform for the image if it's multi-platform. This takes precedence over --os and --arch
*   `--publish-socket <spec>`: Publish a socket from container to host (format: host_path:container_path)
*   `--read-only`: Mount the container's root filesystem as read-only
*   `--rm, --remove`: Remove the container after it stops
*   `--rosetta`: Enable Rosetta in the container
*   `--runtime`: Set the runtime handler for the container (default: container-runtime-linux)
*   `--ssh`: Forward SSH agent socket to container
*   `--shm-size <shm-size>`: Size of `/dev/shm` (e.g. 64M, 1G)
*   `--tmpfs <tmpfs>`: Add a tmpfs mount to the container at the given path
*   `-v, --volume <volume>`: Bind mount a volume into the container
*   `--virtualization`: Expose virtualization capabilities to the container (requires host and guest support)

**Registry Options**

*   `--scheme <scheme>`: Scheme to use when connecting to the container registry. One of (http, https, auto) (default: auto)

    * **Behavior of `auto`**

        When `auto` is selected, the target registry is considered **internal/local** if the registry host matches any of these criteria:
        - The host is a loopback address (e.g., `localhost`, `127.*`)
        - The host is within the `RFC1918` private IP ranges:
            - `10.*.*.*`
            - `192.168.*.*`
            - `172.16.*.*` through `172.31.*.*`
        - The host ends with the machine's default container DNS domain (as defined in `DNSConfig.defaultDomain`, located [here](../Sources/ContainerPersistence/ContainerSystemConfig.swift))

        For internal/local registries, the client uses **HTTP**. Otherwise, it uses **HTTPS**.

**Progress Options**

*   `--progress <type>`: Progress type (format: auto|none|ansi|plain|color) (default: auto)

**Image Fetch Options**

*   `--max-concurrent-downloads <max-concurrent-downloads>`: Maximum number of concurrent downloads (default: 3)

**Examples**

```bash
# run a container and attach an interactive shell
container run -it ubuntu:latest /bin/bash

# run a background web server
container run -d --name web -p 8080:80 nginx:latest

# set environment variables and limit resources
container run -e NODE_ENV=production --cpus 2 --memory 1G node:18

# run a container with a specific MAC address
container run --network default,mac=02:42:ac:11:00:02 ubuntu:latest

# run a container with an init process to reap zombies and forward signals
container run --init ubuntu:latest my-app

# run a container with a custom init image for boot customization
container run --init-image local/custom-init:latest ubuntu:latest
```

### `container build`

Builds an OCI image from a local build context. It reads a Dockerfile (default `Dockerfile`) or Containerfile and produces an image tagged with `-t` option. The build runs in isolation using BuildKit, and resource limits may be set for the build process itself.

When no `-f/--file` is specified, the build command will look for `Dockerfile` first, then fall back to `Containerfile` if `Dockerfile` is not found.

**Usage**

```bash
container build [<options>] [<context-dir>]
```

**Arguments**

*   `<context-dir>`: Build directory (default: .)

**Options**

*   `-a, --arch <value>`: Add the architecture type to the build
*   `--build-arg <key=val>`: Set build-time variables
*   `-c, --cpus <cpus>`: Number of CPUs to allocate to the builder container (default: 2)
*   `--dns <ip>`: DNS nameserver IP address
*   `--dns-domain <domain>`: Default DNS domain
*   `--dns-option <option>`: DNS options
*   `--dns-search <domain>`: DNS search domains
*   `-f, --file <path>`: Path to Dockerfile
*   `-l, --label <key=val>`: Set a label
*   `-m, --memory <memory>`: Amount of builder container memory (1MiByte granularity), with optional K, M, G, T, or P suffix (default: 2048MB)
*   `--no-cache`: Do not use cache
*   `-o, --output <value>`: Output configuration for the build (format: type=<oci|tar|local>[,dest=]) (default: type=oci)
*   `--os <value>`: Add the OS type to the build
*   `--platform <platform>`: Add the platform to the build (format: os/arch[/variant], takes precedence over --os and --arch)
*   `--progress <type>`: Progress type (format: auto|plain|tty) (default: auto)
*   `--pull`: Pull latest image
*   `-q, --quiet`: Suppress build output
*   `--secret <id=key,...>`: Set build-time secrets (format: id=<key>[,env=<ENV_VAR>|,src=<local/path>])
*   `-t, --tag <name>`: Name for the built image (can be specified multiple times)
*   `--target <stage>`: Set the target build stage
*   `--vsock-port <port>`: Builder shim vsock port (default: 8088)

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

# build with multiple tags
container build -t my-app:latest -t my-app:v1.0.0 -t my-app:stable .
```

## Container Management

### `container create`

Creates a container from an image without starting it. This command accepts most of the same process/resource/management flags as `container run`, but leaves the container stopped after creation.

**Usage**

```bash
container create [<options>] <image> [<arguments> ...]
```

**Arguments**

*   `<image>`: Image name
*   `<arguments>`: Container init process arguments

**Process Options**

*   `-e, --env <env>`: Set environment variables (format: key=value, or just key to inherit from host)
*   `--env-file <env-file>`: Read in a file of environment variables (key=value format, ignores # comments and blank lines)
*   `--gid <gid>`: Set the group ID for the process
*   `-i, --interactive`: Keep the standard input open even if not attached
*   `-t, --tty`: Open a TTY with the process
*   `-u, --user <user>`: Set the user for the process (format: name|uid[:gid])
*   `--uid <uid>`: Set the user ID for the process
*   `--ulimit <limit>`: Set resource limits (format: `<type>=<soft>[:<hard>]`)
*   `-w, --workdir, --cwd <dir>`: Set the initial working directory inside the container

**Resource Options**

*   `-c, --cpus <cpus>`: Number of CPUs to allocate to the container
*   `-m, --memory <memory>`: Amount of memory (1MiByte granularity), with optional K, M, G, T, or P suffix

**Management Options**

*   `-a, --arch <arch>`: Set arch if image can target multiple architectures (default: arm64)
*   `--cap-add <cap>`: Add a Linux capability (e.g. `CAP_NET_RAW`, `NET_RAW`, or `ALL`)
*   `--cap-drop <cap>`: Drop a Linux capability (e.g. `CAP_NET_RAW`, `NET_RAW`, or `ALL`)
*   `--cidfile <cidfile>`: Write the container ID to the path provided
*   `-d, --detach`: Run the container and detach from the process
*   `--dns <ip>`: DNS nameserver IP address
*   `--dns-domain <domain>`: Default DNS domain
*   `--dns-option <option>`: DNS options
*   `--dns-search <domain>`: DNS search domains
*   `--entrypoint <cmd>`: Override the entrypoint of the image
*   `--init`: Run an init process inside the container that forwards signals and reaps processes
*   `--init-image <image>`: Use a custom init image instead of the default. This allows customizing boot-time behavior before the OCI container starts, such as running VM-level daemons, configuring eBPF filters, or debugging the init process.
*   `-k, --kernel <path>`: Set a custom kernel path
*   `-l, --label <label>`: Add a key=value label to the container
*   `--mount <mount>`: Add a mount to the container (format: type=<>,source=<>,target=<>,readonly)
*   `--name <name>`: Use the specified name as the container ID
*   `--network <network>`: Attach the container to a network (format: `<name>[,mac=XX:XX:XX:XX:XX:XX][,mtu=VALUE]`)
*   `--no-dns`: Do not configure DNS in the container
*   `--os <os>`: Set OS if image can target multiple operating systems (default: linux)
*   `-p, --publish <spec>`: Publish a port from container to host (format: [host-ip:]host-port:container-port[/protocol])
*   `--platform <platform>`: Platform for the image if it's multi-platform. This takes precedence over --os and --arch
*   `--publish-socket <spec>`: Publish a socket from container to host (format: host_path:container_path)
*   `--read-only`: Mount the container's root filesystem as read-only
*   `--rm, --remove`: Remove the container after it stops
*   `--rosetta`: Enable Rosetta in the container
*   `--runtime`: Set the runtime handler for the container (default: container-runtime-linux)  
*   `--ssh`: Forward SSH agent socket to container
*   `--shm-size <shm-size>`: Size of `/dev/shm` (e.g. 64M, 1G)
*   `--tmpfs <tmpfs>`: Add a tmpfs mount to the container at the given path
*   `-v, --volume <volume>`: Bind mount a volume into the container
*   `--virtualization`: Expose virtualization capabilities to the container (requires host and guest support)

**Registry Options**

*   `--scheme <scheme>`: Scheme to use when connecting to the container registry. One of (http, https, auto) (default: auto)

**Image Fetch Options**

*   `--max-concurrent-downloads <max-concurrent-downloads>`: Maximum number of concurrent downloads (default: 3)

### `container start`

Starts a stopped container. You can attach to the container's output streams and optionally keep STDIN open.

**Usage**

```bash
container start [--attach] [--interactive] [--debug] <container-id>
```

**Arguments**

*   `<container-id>`: Container ID

**Options**

*   `-a, --attach`: Attach stdout/stderr
*   `-i, --interactive`: Attach stdin

### `container stop`

Stops running containers gracefully by sending a signal. A timeout can be specified before a SIGKILL is issued. If no containers are specified, nothing is stopped unless `--all` is used.

**Usage**

```bash
container stop [--all] [--signal <signal>] [--time <time>] [--debug] [<container-ids> ...]
```

**Arguments**

*   `<container-ids>`: Container IDs

**Options**

*   `-a, --all`: Stop all running containers
*   `-s, --signal <signal>`: Signal to send to the containers (default: SIGTERM)
*   `-t, --time <time>`: Seconds to wait before killing the containers (default: 5)

### `container kill`

Immediately kills running containers by sending a signal (defaults to `KILL`). Use with caution: it does not allow for graceful shutdown.

**Usage**

```bash
container kill [--all] [--signal <signal>] [--debug] [<container-ids> ...]
```

**Arguments**

*   `<container-ids>`: Container IDs

**Options**

*   `-a, --all`: Kill or signal all running containers
*   `-s, --signal <signal>`: Signal to send to the container(s) (default: KILL)

### `container delete (rm)`

Deletes one or more containers. If the container is running, you may force deletion with `--force`. Without a container ID, nothing happens unless `--all` is supplied.

**Usage**

```bash
container delete [--all] [--force] [--debug] [<container-ids> ...]
```

**Arguments**

*   `<container-ids>`: Container IDs

**Options**

*   `-a, --all`: Delete all containers
*   `-f, --force`: Delete containers even if they are running

### `container list (ls)`

Lists containers. By default only running containers are shown. Output can be formatted as a table, JSON, YAML, or TOML.

**Usage**

```bash
container list [--all] [--format <format>] [--quiet] [--debug]
```

**Options**

*   `-a, --all`: Include containers that are not running
*   `--format <format>`: Format of the output (values: json, table, yaml, toml; default: table)
*   `-q, --quiet`: Only output the container ID

### `container exec`

Executes a command inside a running container. It uses the same process flags as `container run` to control environment, user, and TTY settings.

**Usage**

```bash
container exec [--detach] [--env <env> ...] [--env-file <env-file> ...] [--gid <gid>] [--interactive] [--tty] [--user <user>] [--uid <uid>] [--workdir <dir>] [--debug] <container-id> <arguments> ...
```

**Arguments**

*   `<container-id>`: Container ID
*   `<arguments>`: New process arguments

**Options**

*   `-d, --detach`: Run the process and detach from it

**Process Options**

*   `-e, --env <env>`: Set environment variables (format: key=value)
*   `--env-file <env-file>`: Read in a file of environment variables (key=value format, ignores # comments and blank lines)
*   `--gid <gid>`: Set the group ID for the process
*   `-i, --interactive`: Keep the standard input open even if not attached
*   `-t, --tty`: Open a TTY with the process
*   `-u, --user <user>`: Set the user for the process (format: name|uid[:gid])
*   `--uid <uid>`: Set the user ID for the process
*   `-w, --workdir, --cwd <dir>`: Set the initial working directory inside the container

### `container export`

Exports a stopped container's filesystem as a tar archive. The container must be stopped before exporting. If no output file is specified, the tar stream is written to stdout.

**Usage**

```bash
container export [-o <output>] [--debug] <container-id>
```

**Arguments**

*   `<container-id>`: Container ID

**Options**

*   `-o, --output <output>`: Pathname for the saved container filesystem (defaults to stdout)

**Examples**

```bash
# export a container's filesystem to a file
container stop mycontainer
container export -o mycontainer.tar mycontainer

# export to stdout and pipe to another tool
container export mycontainer > mycontainer.tar
```

### `container logs`

Fetches logs from a container. You can follow the logs (`-f`/`--follow`), restrict the number of lines shown, or view boot logs.

**Usage**

```bash
container logs [--boot] [--follow] [-n <n>] [--debug] <container-id>
```

**Arguments**

*   `<container-id>`: Container ID

**Options**

*   `--boot`: Display the boot log for the container instead of stdio
*   `-f, --follow`: Follow log output
*   `-n <n>`: Number of lines to show from the end of the logs. If not provided this will print all of the logs

### `container inspect`

Displays detailed container information in JSON. Pass one or more container IDs to inspect multiple containers.

**Usage**

```bash
container inspect [--debug] <container-ids> ...
```

**Arguments**

*   `<container-ids>`: Container IDs

**Options**

No options.

### `container stats`

Displays real-time resource usage statistics for containers. Shows CPU percentage, memory usage, network I/O, block I/O, and process count. By default, continuously updates statistics in an interactive display (like `top`). Use `--no-stream` for a single snapshot.

**Usage**

```bash
container stats [--format <format>] [--no-stream] [--debug] [<container-ids> ...]
```

**Arguments**

*   `<container-ids>`: Container IDs or names (optional, shows all running containers if not specified)

**Options**

*   `--format <format>`: Format of the output (values: json, table, yaml, toml; default: table)
*   `--no-stream`: Disable streaming stats and only pull the first result

**Examples**

```bash
# show stats for all running containers (interactive)
container stats

# show stats for specific containers
container stats web db cache

# get a single snapshot of stats (non-interactive)
container stats --no-stream web

# output stats as JSON
container stats --format json --no-stream web
```

### `container copy (cp)`

Copies files between a container and the local filesystem. The container must be running. One of the source or destination must be a container reference in the form `container_id:path`.

**Usage**

```bash
container copy [--debug] <source> <destination>
```

**Arguments**

*   `<source>`: Source path (local path or `container_id:path`)
*   `<destination>`: Destination path (local path or `container_id:path`)

**Path Format**

*   Local path: `/path/to/file` or `relative/path`
*   Container path: `container_id:/path/in/container`

**Examples**

```bash
# copy a file from host to container
container cp ./config.json mycontainer:/etc/app/

# copy a file from container to host
container cp mycontainer:/var/log/app.log ./logs/

# copy using the full command name
container copy ./data.txt mycontainer:/tmp/
```

### `container prune`

Removes stopped containers to reclaim disk space. The command outputs the amount of space freed after deletion.

**Usage**

```bash
container prune [--debug]
```

**Options**

No options.

## Image Management

### `container image list (ls)`

Lists local images. Verbose output provides additional details such as image ID, creation time and full size; formatted output provides the same data in machine-readable form.

**Usage**

```bash
container image list [--format <format>] [--quiet] [--verbose] [--debug]
```

**Options**

*   `--format <format>`: Format of the output (values: json, table, yaml, toml; default: table)
*   `-q, --quiet`: Only output the image name
*   `-v, --verbose`: Verbose output

### `container image pull`

Pulls an image from a registry. Supports specifying a platform and controlling progress display.

**Usage**

```bash
container image pull [--scheme <scheme>] [--progress <type>] [--max-concurrent-downloads <max-concurrent-downloads>] [--arch <arch>] [--os <os>] [--platform <platform>] [--debug] <reference>
```

**Arguments**

*   `<reference>`: Image reference to pull

**Options**

*   `--scheme <scheme>`: Scheme to use when connecting to the container registry. One of (http, https, auto) (default: auto)
*   `--progress <type>`: Progress type (format: auto|none|ansi|plain|color) (default: auto)
*   `--max-concurrent-downloads <max-concurrent-downloads>`: Maximum number of concurrent downloads (default: 3)
*   `-a, --arch <arch>`: Limit the pull to the specified architecture
*   `--os <os>`: Limit the pull to the specified OS
*   `--platform <platform>`: Limit the pull to the specified platform (format: os/arch[/variant], takes precedence over --os and --arch)

### `container image push`

Pushes an image to a registry. The flags mirror those for `image pull` with the addition of specifying a platform for multi-platform images.

**Usage**

```bash
container image push [--scheme <scheme>] [--progress <type>] [--arch <arch>] [--os <os>] [--platform <platform>] [--debug] <reference>
```

**Arguments**

*   `<reference>`: Image reference to push

**Options**

*   `--scheme <scheme>`: Scheme to use when connecting to the container registry. One of (http, https, auto) (default: auto)
*   `--progress <type>`: Progress type (format: auto|none|ansi|plain|color) (default: auto)
*   `-a, --arch <arch>`: Limit the push to the specified architecture
*   `--os <os>`: Limit the push to the specified OS
*   `--platform <platform>`: Limit the push to the specified platform (format: os/arch[/variant], takes precedence over --os and --arch)

### `container image save`

Saves an image to a tar archive on disk. Useful for exporting images for offline transport.

**Usage**

```bash
container image save [--arch <arch>] [--os <os>] --output <output> [--platform <platform>] [--debug] <references> ...
```

**Arguments**

*   `<references>`: Image references to save

**Options**

*   `-a, --arch <arch>`: Architecture for the saved image
*   `--os <os>`: OS for the saved image
*   `-o, --output <output>`: Pathname for the saved image
*   `--platform <platform>`: Platform for the saved image (format: os/arch[/variant], takes precedence over --os and --arch)

### `container image load`

Loads images from a tar archive created by `image save`. The tar file must be specified via `--input`.

**Usage**

```bash
container image load --input <input> [--force] [--debug]
```

**Options**

*   `-i, --input <input>`: Path to the image tar archive
*   `-f, --force`: Load images even if invalid member files are detected

### `container image tag`

Applies a new tag to an existing image. The original image reference remains unchanged.

**Usage**

```bash
container image tag <source> <target> [--debug]
```

**Arguments**

*   `<source>`: The existing image reference (format: image-name[:tag])
*   `<target>`: The new image reference

**Options**

No options.

### `container image delete (rm)`

Deletes one or more images. If no images are provided, `--all` can be used to delete all images. Images currently referenced by running containers cannot be deleted without first removing those containers.

**Usage**

```bash
container image delete [--all] [--force] [--debug] [<images> ...]
```

**Arguments**

*   `<images>`: Image names or IDs

**Options**

*   `-a, --all`: Delete all images
*   `-f, --force`: Ignore errors for images that are not found

### `container image prune`

Removes unused images to reclaim disk space. By default, only removes dangling images (images with no tags). Use `-a` to remove all images not referenced by any container.

**Usage**

```bash
container image prune [--all] [--debug]
```

**Options**

*   `-a, --all`: Remove all unused images, not just dangling ones

### `container image inspect`

Shows detailed information for one or more images in JSON format. Accepts image names or IDs.

**Usage**

```bash
container image inspect [--debug] <images> ...
```

**Arguments**

*   `<images>`: Images to inspect

**Options**

No options.

## Builder Management

The builder commands manage the BuildKit-based builder used for image builds.

### `container builder start`

Starts the BuildKit builder container. CPU and memory limits can be set for the builder.

**Usage**

```bash
container builder start [--cpus <cpus>] [--memory <memory>] [--dns <ip> ...] [--dns-domain <domain>] [--dns-option <option> ...] [--dns-search <domain> ...] [--debug]
```

**Options**

*   `-c, --cpus <cpus>`: Number of CPUs to allocate to the builder container (default: 2)
*   `-m, --memory <memory>`: Amount of builder container memory (1MiByte granularity), with optional K, M, G, T, or P suffix (default: 2048MB)
*   `--dns <ip>`: DNS nameserver IP address
*   `--dns-domain <domain>`: Default DNS domain
*   `--dns-option <option>`: DNS options
*   `--dns-search <domain>`: DNS search domains

### `container builder status`

Shows the current status of the BuildKit builder. Without flags a human-readable table is displayed; formatted output is available for scripting.

**Usage**

```bash
container builder status [--format <format>] [--quiet] [--debug]
```

**Options**

*   `--format <format>`: Format of the output (values: json, table, yaml, toml; default: table)
*   `-q, --quiet`: Only output the container ID

### `container builder stop`

Stops the BuildKit builder container.

**Usage**

```bash
container builder stop [--debug]
```

**Options**

No options.

### `container builder delete (rm)`

Deletes the BuildKit builder container. It can optionally force deletion if the builder is still running.

**Usage**

```bash
container builder delete [--force] [--debug]
```

**Options**

*   `-f, --force`: Delete the builder even if it is running

## Network Management (macOS 26+)

The network commands are available on macOS 26 and later and allow creation and management of user-defined container networks.

### `container network create`

Creates a new network with the given name.

**Usage**

```bash
container network create [--internal] [--label <label> ...] [--option <option> ...] [--plugin <plugin>] [--subnet <subnet>] [--subnet-v6 <subnet-v6>] [--debug] <name>
```

**Arguments**

*   `<name>`: Network name

**Options**

*   `--internal`: Restrict to host-only network
*   `--label <label>`: Set metadata for a network
*   `--option <option>`: Set a plugin-specific option (key=value); may be repeated
*   `--plugin <plugin>`: Network plugin to use (default: `container-network-vmnet`)
*   `--subnet <subnet>`: Set the IPv4 subnet for a network (CIDR format, e.g., 192.168.100.0/24)
*   `--subnet-v6 <subnet-v6>`: Set the IPv6 prefix for a network (CIDR format, e.g., fd00:1234::/64)

### `container network delete (rm)`

Deletes one or more networks. When deleting multiple networks, pass them as separate arguments. To delete all networks, use `--all`.

**Usage**

```bash
container network delete [--all] [--debug] [<network-names> ...]
```

**Arguments**

*   `<network-names>`: Network names

**Options**

*   `-a, --all`: Delete all networks

### `container network prune`

Removes networks not connected to any containers. However, default and system networks are preserved.

**Usage**

```bash
container network prune [--debug]
```

**Options**

No options.

### `container network list (ls)`

Lists user-defined networks.

**Usage**

```bash
container network list [--format <format>] [--quiet] [--debug]
```

**Options**

*   `--format <format>`: Format of the output (values: json, table, yaml, toml; default: table)
*   `-q, --quiet`: Only output the network name

### `container network inspect`

Shows detailed information about one or more networks.

**Usage**

```bash
container network inspect <networks> ... [--debug]
```

**Arguments**

*   `<networks>`: Networks to inspect

**Options**

No options.

## Volume Management

Manage persistent volumes for containers. Volumes can be explicitly created with `volume create` or implicitly created when referenced in container commands (e.g., `-v myvolume:/path` or `-v /path` for anonymous volumes).

### `container volume create`

Creates a new named volume with an optional size and driver-specific options.

**Usage**

```bash
container volume create [--label <label> ...] [--opt <opt> ...] [-s <s>] [--debug] <name>
```

**Arguments**

*   `<name>`: Volume name

**Options**

*   `--label <label>`: Set metadata for a volume
*   `--opt <opt>`: Set driver specific options
*   `-s <s>`: Size of the volume in bytes, with optional K, M, G, T, or P suffix. Takes precedence over `--opt size=` if both are specified.

**Driver Options**

Driver options are passed with `--opt key=value`. The following options are supported for the default `local` driver:

*   `size=<value>`: Volume size with optional unit suffix (K, M, G, T, P). Minimum 1 MiB. Equivalent to `-s`; if `-s` is also specified, `-s` takes precedence.
*   `journal=<mode>[:<size>]`: Configure ext4 journaling on the volume. `<mode>` must be one of:
    *   `ordered` — journals metadata only; data is written to disk before its metadata is committed (default kernel behavior, good balance of safety and performance)
    *   `writeback` — journals metadata only; data ordering relative to metadata commits is not guaranteed (fastest, least safe)
    *   `journal` — journals both metadata and data (safest, highest write amplification)

    An optional `:<size>` suffix sets the journal size (same unit suffixes as `size`). If omitted, the kernel selects a default journal size.

**Examples**

```bash
# create a volume with ordered journaling
container volume create --opt journal=ordered myvolume

# create a volume with writeback journaling and a 64 MiB journal
container volume create --opt journal=writeback:64m myvolume

# create a volume with full data journaling and an explicit volume size
container volume create --opt journal=journal --opt size=10g myvolume
```

**Anonymous Volumes**

Anonymous volumes are auto-created when using `-v /path` or `--mount type=volume,dst=/path` without specifying a source. They use UUID-based naming (`anon-{36-char-uuid}`):

```bash
# Creates anonymous volume
container run -v /data alpine

# Reuse anonymous volume by ID
VOL=$(container volume list -q | grep anon)
container run -v $VOL:/data alpine

# Manual cleanup
container volume rm $VOL
```

> [!NOTE]
> Unlike Docker, anonymous volumes do NOT auto-cleanup with `--rm`. Manual deletion is required.

### `container volume delete (rm)`

Deletes one or more volumes by name. Volumes that are currently in use by containers (running or stopped) cannot be deleted.

**Usage**

```bash
container volume delete [--all] [--debug] [<names> ...]
```

**Arguments**

*   `<names>`: Volume names

**Options**

*   `-a, --all`: Delete all volumes

**Examples**

```bash
# delete a specific volume
container volume delete myvolume

# delete multiple volumes
container volume delete vol1 vol2 vol3

# delete all unused volumes
container volume delete --all
```

### `container volume prune`

Removes all volumes that have no container references. This includes volumes that are not attached to any running or stopped containers. The command reports the actual disk space reclaimed after deletion.

**Usage**

```bash
container volume prune [--debug]
```

**Options**

No options.

### `container volume list (ls)`

Lists volumes.

**Usage**

```bash
container volume list [--format <format>] [--quiet] [--debug]
```

**Options**

*   `--format <format>`: Format of the output (values: json, table, yaml, toml; default: table)
*   `-q, --quiet`: Only output the volume name

### `container volume inspect`

Displays detailed information for one or more volumes in JSON.

**Usage**

```bash
container volume inspect [--debug] <names> ...
```

**Arguments**

*   `<names>`: Volume names

**Options**

No options.

## Registry Management

The registry commands manage authentication and defaults for container registries.

### `container registry login`

Authenticates with a registry. Credentials can be provided interactively or via flags. The login is stored for reuse by subsequent commands.

**Usage**

```bash
container registry login [--scheme <scheme>] [--password-stdin] [--username <username>] [--debug] <server>
```

**Arguments**

*   `<server>`: Registry server name

**Options**

*   `--scheme <scheme>`: Scheme to use when connecting to the container registry. One of (http, https, auto) (default: auto)
*   `--password-stdin`: Take the password from stdin
*   `-u, --username <username>`: Registry user name

### `container registry logout`

Logs out of a registry, removing stored credentials.

**Usage**

```bash
container registry logout [--debug] <registry>
```

**Arguments**

*   `<registry>`: Registry server name

**Options**

No options.

### `container registry list`

List image registry logins.

**Usage**

```bash
container registry list [--format <format>] [--quiet] [--debug]
```

**Options**

*   `--format <format>`: Format of the output (values: json, table, yaml, toml; default: table)
*   `-q, --quiet`: Only output the registry hostname

## Container Machine Management

`m` is an alias for `container machine`.

### `container machine create`

Creates a container machine from an image and boots it. Use `--cpus`, `--memory`, and `--home-mount` to configure it, or `--no-boot` to create it without booting.

**Usage**

```bash
container machine create [<options>] <image>
```

**Arguments**

*   `<image>`: Container image reference (e.g., alpine:3.22)

**Options**

*   `-n, --name <name>`: Name for the container machine
*   `--set-default`: Set this container machine as the default
*   `--no-boot`: Create the container machine without booting it
*   `--cpus <cpus>`: Number of virtual CPUs
*   `--memory <memory>`: Memory allocation (e.g., 2G, 8G). Default: half of system memory
*   `--home-mount <home-mount>`: User's home directory mount option (ro, rw, none). Default: rw

**Management Options**

*   `-a, --arch <arch>`: Set arch if image can target multiple architectures (default: host architecture)
*   `--os <os>`: Set OS if image can target multiple operating systems (default: linux)
*   `--platform <platform>`: Platform for the image if it's multi-platform. This takes precedence over --os and --arch

**Registry Options**

*   `--scheme <scheme>`: Scheme to use when connecting to the container registry. One of (http, https, auto) (default: auto)

**Progress Options**

*   `--progress <type>`: Progress type (format: auto|none|ansi|plain|color) (default: auto)

**Image Fetch Options**

*   `--max-concurrent-downloads <max-concurrent-downloads>`: Maximum number of concurrent downloads (default: 3)

**Examples**

```bash
# create and boot a container machine named my-machine
container machine create alpine:3.22 --name my-machine

# create a container machine with custom resources and set it as the default
container machine create --cpus 4 --memory 8G --set-default alpine:3.22

# create a container machine without booting it
container machine create --no-boot alpine:3.22
```

### `container machine run`

Runs a command in a container machine, booting it first if needed. With no command, it opens an interactive login shell. By default the command runs as a user matching the host user.

**Usage**

```bash
container machine run [<options>] [<executable>] [<arguments> ...]
```

**Arguments**

*   `<executable>`: Command to run (default: login shell)
*   `<arguments>`: Command arguments

**Options**

*   `-n, --name <name>`: Container machine ID (uses default if not specified)
*   `-d, --detach`: Run a process in a container machine and detach from it
*   `--root`: Run as root instead of matching host user

**Process Options**

*   `-e, --env <env>`: Set environment variables (format: key=value, or just key to inherit from host)
*   `--env-file <env-file>`: Read in a file of environment variables (key=value format, ignores # comments and blank lines)
*   `--gid <gid>`: Set the group ID for the process
*   `-i, --interactive`: Keep the standard input open even if not attached
*   `-t, --tty`: Open a TTY with the process
*   `-u, --user <user>`: Set the user for the process (format: name|uid[:gid])
*   `--uid <uid>`: Set the user ID for the process
*   `-w, --workdir, --cwd <dir>`: Set the initial working directory inside the container

**Examples**

```bash
# open an interactive shell in the default container machine
container machine run

# run a command in a named container machine
container machine run -n my-machine uname -a

# pass arguments to the command after --
container machine run -n my-machine -- cat /proc/cpuinfo
```

### `container machine list (ls)`

Lists container machines. The default container machine is marked in the `DEFAULT` column.

**Usage**

```bash
container machine list [--format <format>] [--quiet] [--debug]
```

**Options**

*   `--format <format>`: Format of the output (values: json, table; default: table)
*   `-q, --quiet`: Only output the container machine ID

### `container machine inspect`

Displays detailed information about a container machine in JSON. Uses the default container machine if no ID is given.

**Usage**

```bash
container machine inspect [--debug] [<id>]
```

**Arguments**

*   `<id>`: Container machine ID (uses default if not specified)

**Options**

No options.

### `container machine set`

Sets configuration values on a container machine. Changes take effect after the container machine is stopped and restarted. Uses the default container machine if no ID is given.

**Usage**

```bash
container machine set [--name <name>] [--debug] <setting> ...
```

**Arguments**

*   `<setting>`: Configuration values (format: key=value)

**Settings**

*   `cpus=<number>`: Number of virtual CPUs
*   `memory=<size>`: Memory allocation (e.g., 2G, 1G). Default: half of system memory
*   `home-mount=<string>`: User home directory mount option (ro, rw, none). Default: rw

**Options**

*   `-n, --name <name>`: Container machine ID (uses default if not specified)

**Examples**

```bash
# set CPUs and memory on the default container machine
container machine set cpus=4 memory=8G

# update the home mount on a named container machine
container machine set -n my-machine home-mount=ro
```

### `container machine set-default`

Sets the default container machine. Commands that take an optional container machine ID use the default when you don't provide one.

**Usage**

```bash
container machine set-default [--debug] <id>
```

**Arguments**

*   `<id>`: Container machine ID

**Options**

No options.

### `container machine logs`

Fetches logs from a container machine. You can follow output, limit the number of lines, or view the boot log. Uses the default container machine if no ID is given.

**Usage**

```bash
container machine logs [--boot] [--follow] [-n <n>] [--debug] [<id>]
```

**Arguments**

*   `<id>`: Container machine ID (uses default if not specified)

**Options**

*   `--boot`: Display the boot log for the container machine instead of stdio
*   `-f, --follow`: Follow log output
*   `-n <n>`: Number of lines to show from the end of the logs. If not provided this will print all of the logs

### `container machine stop`

Stops a running container machine. Uses the default container machine if no ID is given.

**Usage**

```bash
container machine stop [--debug] [<id>]
```

**Arguments**

*   `<id>`: Container machine ID (uses default if not specified)

**Options**

No options.

### `container machine delete (rm)`

Deletes a container machine, stopping it first if it is running. If it was the default, set a new one with `container machine set-default`.

**Usage**

```bash
container machine delete [--debug] <id>
```

**Arguments**

*   `<id>`: Container machine ID

**Options**

No options.

## System Management

System commands manage the container apiserver, logs, DNS settings and kernel. These are only available on macOS hosts.

### `container system start`

Starts the container services and (optionally) installs a default kernel. It will start the `container-apiserver` and background services.

**Usage**

```bash
container system start [--app-root <app-root>] [--install-root <install-root>] [--log-root <log-root>] [--enable-kernel-install] [--disable-kernel-install] [--timeout <timeout>] [--debug]
```

**Options**

*   `-a, --app-root <app-root>`: Path to the root directory for application data
*   `--install-root <install-root>`: Path to the root directory for application executables and plugins
*   `--log-root <log-root>`: Path to the root directory for log data, using macOS log facility if not set
*   `--enable-kernel-install/--disable-kernel-install`: Specify whether the default kernel should be installed or not (default: prompt user)
*   `--timeout <timeout>`: Number of seconds to wait for API service to become responsive

> [!NOTE]
> The `--log-root` option is principally intended for short-term test and diagnostic purposes. The log handler for this option neither aggregates log messages, nor does it rotate logs.

### `container system stop`

Stops the container services and deregisters them from launchd. You can specify a prefix to target services created with a different launchd prefix.

**Usage**

```bash
container system stop [--prefix <prefix>] [--debug]
```

**Options**

*   `-p, --prefix <prefix>`: Launchd prefix for services (default: com.apple.container.)

### `container system status`

Checks whether the container services are running and prints status information. It sends a health check request to the API server, which returns basic system information.

**Usage**

```bash
container system status [--prefix <prefix>] [--format <format>] [--debug]
```

**Options**

*   `-p, --prefix <prefix>`: Launchd prefix for services (default: com.apple.container.)
*   `--format <format>`: Format of the output (values: json, table, yaml, toml; default: table)

### `container system version`

Shows version information for the CLI and, if available, the API server. The table format is consistent with other list outputs and includes a header. If the API server responds to a health check, a second row for the server is added.

**Usage**

```bash
container system version [--format <format>] [--debug]
```

**Options**

*   `--format <format>`: Format of the output (values: json, table, yaml, toml; default: table)

**Table Output**

Columns: `COMPONENT`, `VERSION`, `BUILD`, `COMMIT`.

Example:

```bash
container system version
```

```
COMPONENT            VERSION                                                             BUILD    COMMIT
container            1.2.3                                                               debug    abcdef1
container-apiserver  container-apiserver version 1.2.3 (build: release, commit: 1234abc)  release  1234abcdef
```

**JSON Output**

Each entry in the array represents a component. If the API server responds to a health check, a second entry is included. The API server's `version` field is its full single-line version string.

```json
[
  {
    "appName": "container",
    "buildType": "debug",
    "commit": "abcdef1",
    "version": "1.2.3"
  },
  {
    "appName": "container-apiserver",
    "buildType": "release",
    "commit": "1234abcdef",
    "version": "container-apiserver version 1.2.3 (build: release, commit: 1234abc)"
  }
]
```

**YAML Output**

Equivalent to the JSON output but in YAML format.

```yaml
- version: 1.2.3
  buildType: debug
  commit: abcdef1
  appName: container
- version: 'container-apiserver version 1.2.3 (build: release, commit: 1234abc)'
  buildType: release
  commit: 1234abcdef
  appName: container-apiserver
```

**TOML Output**

TOML output wraps the component array under an `items` key.

```toml
[[items]]
appName = "container"
buildType = "debug"
commit = "abcdef1"
version = "1.2.3"

[[items]]
appName = "container-apiserver"
buildType = "release"
commit = "1234abcdef"
version = "container-apiserver version 1.2.3 (build: release, commit: 1234abc)"
```

### `container system logs`

Displays logs from the container services. You can specify a time interval or follow new logs in real time.

> [!NOTE]
> If you run `container system start --log-root`, services only write log messages to files under the log root, and `container system logs` will show no service log messages.

**Usage**

```bash
container system logs [--follow] [--last <last>] [--debug]
```

**Options**

*   `-f, --follow`: Follow log output
*   `--last <last>`: Fetch logs starting from the specified time period (minus the current time); supported formats: m, h, d (default: 5m)

### `container system df`

Shows disk usage for images, containers, and volumes. Displays total count, active count, size, and reclaimable space for each resource type.

**Usage**

```bash
container system df [--format <format>] [--debug]
```

**Options**

*   `--format <format>`: Format of the output (values: json, table, yaml, toml; default: table)

### `container system dns create`

Creates a local DNS domain for containers. Requires administrator privileges (use sudo).

**Usage**

```bash
container system dns create [--debug] [--localhost <localhost>] <domain-name>
```

**Arguments**

*   `<domain-name>`: The local domain name

**Options**

*   `--localhost <localhost>`: Set the IP address to be redirected to localhost

### `container system dns delete (rm)`

Deletes a local DNS domain. Requires administrator privileges (use sudo).

**Usage**

```bash
container system dns delete [--debug] <domain-name>
```

**Arguments**

*   `<domain-name>`: The local domain name

**Options**

No options.

### `container system dns list (ls)`

Lists configured local DNS domains for containers.

**Usage**

```bash
container system dns list [--format <format>] [--quiet] [--debug]
```

**Options**

*   `--format <format>`: Format of the output (values: json, table, yaml, toml; default: table)
*   `-q, --quiet`: Only output the domain

### `container system kernel set`

Installs or updates the Linux kernel used by the container runtime on macOS hosts.

**Usage**

```bash
container system kernel set [--arch <arch>] [--binary <binary>] [--force] [--recommended] [--tar <tar>] [--debug]
```

**Options**

*   `--arch <arch>`: The architecture of the kernel binary (values: amd64, arm64) (default: arm64)
*   `--binary <binary>`: Path to the kernel file (or archive member, if used with --tar)
*   `--force`: Overwrites an existing kernel with the same name
*   `--recommended`: Download and install the recommended kernel as the default (takes precedence over all other flags)
*   `--tar <tar>`: Filesystem path or remote URL to a tar archive containing a kernel file

### `container system property list (ls)`

Lists all system properties with their current values. Output can be formatted as JSON or TOML.

**Usage**

```bash
container system property list [--format <format>] [--debug]
```

**Options**

*   `--format <format>`: Format of the output (values: json, toml; default: toml)

**Examples**

```bash
# list all properties in TOML format (default)
container system property list

# output as JSON for scripting
container system property list --format json
```
