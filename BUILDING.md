# Building the project

To build the `container` project, you need:

- Mac with Apple silicon
- macOS 15 minimum, macOS 26 recommended
- Xcode 26, set as the [active developer directory](https://developer.apple.com/library/archive/technotes/tn2339/_index.html#//apple_ref/doc/uid/DTS40014588-CH1-HOW_DO_I_SELECT_THE_DEFAULT_VERSION_OF_XCODE_TO_USE_FOR_MY_COMMAND_LINE_TOOLS_)

> [!IMPORTANT]
> There is a bug in the `vmnet` framework on macOS 26 that causes network creation to fail if the `container` helper applications are located under your `Documents` or `Desktop` directories. If you use `make install`, you can simply run the `container` binary in `/usr/local`. If you prefer to use the binaries that `make all` creates in your project `bin` and `libexec` directories, locate your project elsewhere, such as `~/projects/container`, until this issue is resolved.

## Compile and test

Build `container` and the background services from source, then run the unit and integration tests in an isolated application data directory:

```bash
make verify
```

This is the quickest way to verify your toolchain after cloning. `make verify` runs the `all`, `test`, and `integration` targets. The integration suite boots virtual machines and downloads a kernel and images, so the first run takes a while.

> [!IMPORTANT]
> `make integration` stops any `container` services you already have running and leaves them stopped when it finishes; run `container system start` afterward to get back to your own installation.

### Build and test targets

| Target | What it does |
| --- | --- |
| `make verify` | Runs `all`, `test`, and `integration`. |
| `make all` | Compiles, then installs the binaries into `bin/` and `libexec/` in your project directory. |
| `make test` | Runs the unit tests. |
| `make integration` | Runs the CLI and integration test suites. These start the `container` services, create containers, and boot virtual machines. |
| `make install` | Builds an installer package and installs it to `/usr/local`. |
| `make clean` | Runs `cleantest`, then `cleanbuild`. |
| `make cleanbuild` | Removes `bin/`, `libexec/`, generated docs, and coverage output. |
| `make cleantest` | Stops the `container` services and removes the `APP_ROOT` and `SCRATCH_ROOT` directories. |

### Isolating test data with `APP_ROOT`

By default, the test targets use `.test-data` in your project directory, so they do not disturb the images, containers, and volumes you use day to day, which live in `~/Library/Application Support/com.apple.container`.

`APP_ROOT` sets that directory, and is passed as `--app-root` to the services the test targets start.

How `make integration` treats `APP_ROOT`:
- It erases the directory's contents before each run.
- Set `APP_ROOT=` (empty) to run against `~/Library/Application Support/com.apple.container` instead. The tests will not erase it, but they will create and delete containers in it. Use this when you want the tests to exercise a realistic installation.

### Recommended iteration loop

> [!IMPORTANT]
> If you have an instance of `container` running, stop it using `container system stop` before starting the dev CLI. Each user account has a single set of `com.apple.container.*` services, so a test run cannot coexist with an installation you are using.

```bash
# 1. Build
make all

# 2. Unit tests
make test

# 3. Test the dev CLI
./bin/container system start --app-root .test-data
```

### Integration test options

| Variable | Default | Effect |
| --- | --- | --- |
| `PRESERVE_KERNELS` | `false` | Set to `true` to keep the `kernels` directory when the run clears `APP_ROOT`, so repeated runs do not download the kernel again. |
| `LOG_ROOT` | unset | Passes `--log-root` to the services, and writes swift-testing event streams to the given path. |

A typical iteration on the integration tests:

```bash
make PRESERVE_KERNELS=true LOG_ROOT=.test-data/logs integration
```

### Build installer package

Copy the binaries to `/usr/local/bin` and `/usr/local/libexec` (requires entering an administrator password):

```bash
make install
```

Or to install a release build, with better performance than the debug build:

```bash
BUILD_CONFIGURATION=release make verify
BUILD_CONFIGURATION=release make install
```

### Clean up

Stop the services, remove the build outputs, and delete the test directories:

```bash
make clean
```

Use `make cleanbuild` to remove only the build outputs, or `make cleantest` to stop the services and remove only the `APP_ROOT` and `SCRATCH_ROOT` directories.

## Compile protobufs

`container` uses gRPC to communicate to the builder virtual machine that creates images from `Dockerfile`s, and depends on specific versions of `grpc-swift` and `swift-protobuf`. If you make changes to the gRPC APIs in the [container-builder-shim](https://github.com/apple/container-builder-shim) project, install the tools and re-generate the gRPC code in this project using:

```bash
make protos
```

## Develop using a local copy of Containerization

To make changes to `container` that require changes to the Containerization project, or vice versa:

1. Clone the [Containerization](https://github.com/apple/containerization) repository such that it sits next to your clone
of the `container` repository. Ensure that you [follow containerization instructions](https://github.com/apple/containerization/blob/main/README.md#prepare-to-build-package)
to prepare your build environment.

2. In your development shell, go to the `container` project directory.

    ```bash
    cd container
    ```

3. If the `container` services are already running, stop them.

    ```bash
    bin/container system stop
    ```

4. Reconfigure the Swift project to use your local `containerization` package and update your `Package.resolved` file.

    ```bash
    /usr/bin/swift package edit --path ../containerization containerization
    /usr/bin/swift package update containerization
    ```

    > [!IMPORTANT]
    > If you are using Xcode, do **not** run `swift package edit`. Instead, temporarily modify `Package.swift` to replace the versioned `containerization` dependency:
    >
    > ```swift
    > .package(url: "https://github.com/apple/containerization.git", exact: Version(stringLiteral: scVersion)),
    > ```
    >
    > with the local path dependency:
    >
    > ```swift
    > .package(path: "../containerization"),
    > ```
    >
    > **Note:** If you have already run `swift package edit`, whether intentionally or by accident, follow the steps in the next section to restore the normal `containerization` dependency. Otherwise, the modified `Package.swift` file will not work, and the project may fail to build.

5. If you want `container` to use any changes you made in the `vminit` subproject of Containerization, set the init image in your runtime configuration file at `~/.config/container/config.toml`:

    ```toml
    [vminit]
    image = "vminit:latest"
    ```

6. Build `container`.

    ```
    make APP_ROOT= clean all
    ```

7. Restart the `container` services.

    ```
    bin/container system stop
    bin/container system start
    ```

To revert to using the Containerization dependency from your `Package.swift`:

1. If you were using the local init filesystem, remove the `init` override from your `~/.config/container/config.toml` (or delete the `[vminit]` section if no other image settings are present).

2. Use the Swift package manager to restore the normal `containerization` dependency and update your `Package.resolved` file. If you are using Xcode, revert your `Package.swift` change instead of using `swift package unedit`.

    ```bash
    /usr/bin/swift package unedit containerization
    /usr/bin/swift package update containerization
    ```

3. Rebuild `container`.

    ```bash
    make clean all
    ```

4. Restart the `container` services.

    ```bash
    bin/container system stop
    bin/container system start
    ```

## Develop using a local copy of container-builder-shim

To test changes that require the `container-builder-shim` project:

1. Clone the [container-builder-shim](https://github.com/apple/container-builder-shim) repository and navigate to its directory.

2. After making the necessary changes, build the custom builder image, set it as the active builder image in `~/.config/container/config.toml`, and remove the existing `buildkit` container so the new image will be used:

```bash
container build -t builder .
container rm -f buildkit
```

Add the following to your `~/.config/container/config.toml`:

```toml
[build]
image = "builder:latest"
```

3. Run the `container` build as usual:

```bash
container build ...
```

> [!IMPORTANT]
> If your modified builder image is broken, make sure to rebuild and correctly tag the builder image before attempting to build `container-builder-shim` again.

## Debug XPC Helpers

Attach debugger to the XPC helpers using their launchd service labels:

1. Find launchd service labels:

   ```console
   % container system start
   % container run -d --name test debian:bookworm sleep infinity
   test
   % launchctl list | grep container
   27068   0       com.apple.container.container-network-vmnet.default
   27072   0       com.apple.container.container-core-images
   26980   0       com.apple.container.apiserver
   27331   0       com.apple.container.container-runtime-linux.test
   ```

2. Stop container and start again after setting the environment variable `CONTAINER_DEBUG_LAUNCHD_LABEL` to the label of service to attach debugger. Services whose label starts with the `CONTAINER_DEBUG_LAUNCHD_LABEL` will wait the debugger:

    ```console
    % export CONTAINER_DEBUG_LAUNCHD_LABEL=com.apple.container.container-runtime-linux.test
    % container system start # Only the service `com.apple.container.container-runtime-linux.test` waits debugger
    ```

    ```console
    % export CONTAINER_DEBUG_LAUNCHD_LABEL=com.apple.container.container-runtime-linux
    % container system start # Every service starting with `com.apple.container.container-runtime-linux` waits debugger
    ```

3. Run the command to launch the service, and attach debugger:

    ```console
    % container run -it --name test debian:bookworm
    ⠧ [6/6] Starting container [0s] # It hangs as the service is waiting for debugger
    ```

## Pre-commit hook

Run `make pre-commit` to install a pre-commit hook that ensures that your changes have correct formatting and license headers when you run `git commit`.
