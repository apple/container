# Building the project

To build the `container` project, you need:

- Mac with Apple silicon
- macOS 15 minimum, macOS 26 recommended
- Xcode 26, set as the [active developer directory](https://developer.apple.com/library/archive/technotes/tn2339/_index.html#//apple_ref/doc/uid/DTS40014588-CH1-HOW_DO_I_SELECT_THE_DEFAULT_VERSION_OF_XCODE_TO_USE_FOR_MY_COMMAND_LINE_TOOLS_)

> [!IMPORTANT]
> There is a bug in the `vmnet` framework on macOS 26 that causes network creation to fail if the `container` helper applications are located under your `Documents` or `Desktop` directories. If you use `make install`, you can simply run the `container` binary in `/usr/local`. If you prefer to use the binaries that `make all` creates in your project `bin` and `libexec` directories, locate your project elsewhere, such as `~/projects/container`, until this issue is resolved.

## Compile and test

Build `container` and the background services from source, and run basic and integration tests:

```bash
make all test integration
```

Copy the binaries to `/usr/local/bin` and `/usr/local/libexec` (requires entering an administrator password):

```bash
make install
```

Or to install a release build, with better performance than the debug build:

```bash
BUILD_CONFIGURATION=release make all test integration
BUILD_CONFIGURATION=release make install
```

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

4. Use the Swift package manager to configure use your local `containerization` package and update your `Package.resolved` file.

    ```bash
    /usr/bin/swift package edit --path ../containerization containerization
    /usr/bin/swift package update containerization
    ```

    > [!IMPORTANT]
    > If you are using Xcode, you will need to temporarily modify `Package.swift` instead of using `swift package edit`, using a path dependency in place of the versioned `container` dependency:
    >
    >    ```swift
    >    .package(path: "../containerization"),
    >    ```

5. If you want `container` to use any changes you made in the `vminit` subproject of Containerization, update the system property to use the locally built init filesystem image:

    ```bash
    container system property set image.init vminit:latest 
    ```

6. Build `container`.

    ```
    make clean all
    ```

7. Restart the `container` services.

    ```
    bin/container system stop
    bin/container system start
    ```

To revert to using the Containerization dependency from your `Package.swift`:

1. If you were using the local init filesystem, revert the system property to its default value:

    ```bash
    container system property clear image.init
    ```

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

## Pre-commit hook

Run `make pre-commit` to install a pre-commit hook that ensures that your changes have correct formatting and license headers when you run `git commit`.
