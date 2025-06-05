# `container`

![introductory movie showing some basic commands](./docs/assets/landing-movie.gif)

`container` is an application that you can use to create and run Linux containers as lightweight virtual machines on your Mac. It's written in Swift, and optimized for Apple Silicon. 

The application consumes and produces OCI-compliant container images, so you can pull and run images from any standard container registry. You can push images that you build to those registries as well, and run the images in any other OCI-compliant application.

`container` uses the [Containerization](https://github.com/apple/containerization) Swift package for low level container, image and process management.

## Get started

Install the `container` application on your Mac.

### Requirements

You need an Apple Silicon Mac to build and run `container`.

To build the Containerization package, your system needs either:

- macOS 15 or newer and Xcode 17 beta.
- macOS 16 Developer Preview.

`container` is designed to take advantage of the features of the macOS 16 Developer Preview. You can run the application on macOS Sequoia, but the `container` maintainers typically will not address Sequoia issues that cannot be reproduced on the macOS 16 Developer Beta.

There are [significant networking limitations](https://github.com/apple/container#macos-sequoia-limitations) that impact the usability `container` on macOS Sequoia.

### Install or upgrade

If you're upgrading, first uninstall your existing `container` while preserving your user data:

```bash
uninstall-container.sh -k
```

Download the latest application installer package from the [Github release page](https://github.com/apple/container/releases).

To install the application, double click the package file and follow the instructions. Enter your administrator password when prompted to give the installer permission to place the application under `/usr/local`.

### Uninstall

Use the `uninstall-container.sh` script to remove the application from your system. To remove your user data along with the application, run:

```bash
uninstall-container.sh -d
```

To retain your user data so that it is available should you reinstall later, run:

```bash
uninstall-container.sh -k
```

## Build the application from source

Build `container` and the background services from sources and run basic and integration tests:

```bash
make all test integration
```

Copy the binaries to `/usr/local/bin` and `/usr/local/libexec` (requires entering the administrator's password):

```bash
make install
```

### Protobufs

`container` depends on specific versions of `grpc-swift` and `swift-protobuf`. You can install them and re-generate RPC interfaces with:

```bash
make protos
```

## Contributing 

Contributions are welcome and encouraged! Read our [main contributing guide](https://github.com/apple/containerization/blob/main/CONTRIBUTING.md) to get started.  If you're developing using a local copy of 
Containerization read the [docs here](./docs/localSwiftContainerization.md)

 ## More Info:

- Take [a guided tour of `container`](./docs/tutorial.md) by building, running, and publishing a simple web server image.
- Read through [How to use the features of `container`.](./docs/how-to.md)
- A brief description and [technical overview](./docs/technical-overview.md) of `container`.

