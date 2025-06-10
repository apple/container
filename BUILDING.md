# Building the project

To build the `container` project, your system needs either:

- macOS 15 or newer and Xcode 26 Beta
- macOS 26 Beta 1 or newer

## Compile and test

Build `container` and the background services from source, and run basic and integration tests:

```bash
make all test integration
```

Copy the binaries to `/usr/local/bin` and `/usr/local/libexec` (requires entering an administrator password):

```bash
make install
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

    ```
    cd container
    ```

3. If the `container` services are already running, stop them.

    ```
    bin/container system stop
    ```

4. Configure the environment variable `CONTAINERIZATION_PATH` to refer to your Containerization project, and update your `Package.resolved` file.

    ```
    export CONTAINERIZATION_PATH=../containerization
    swift package update containerization
    ```

5. Build the init filesystem for your local copy of the Containerization project.

    ```
    (cd ${CONTAINERIZATION_PATH} && make clean all)
    ```

6. Build `container`.

    ```
    make clean all
    ```

7. Start the `container` services.

    ```
    bin/container system start
    ```

To revert to using the Containerization dependency from your `Package.swift`:

1. Unset your `CONTAINERIZATION_PATH` environment variable, and update `Package.resolved`.

    ```
    unset CONTAINERIZATION_PATH
    swift package update containerization
    ```

2. Rebuild `container`.

    ```
    make clean all
    ```

3. Restart the `container` services.

    ```
    bin/container system restart
    ```
