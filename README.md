![introductory movie showing some basic commands](./docs/assets/landing-movie.gif)

# `container`

`container` is an application that you can use to create and run Linux containers as lightweight virtual machines on your Mac. It's written in Swift, and optimized for Apple Silicon. 

The application consumes and produces OCI-compliant container images, so you can pull and run images from any standard container registry. You can push images that you build to those registries as well, and run the images in any other OCI-compliant application.

`container` uses the [Containerization](https://github.com/apple/containerization) Swift package for low level container, image and process management.

## Get started

Install the `container` application on your Mac.

### Requirements

You need an Apple Silicon Mac to run `container`. To build the application, see the [BUILDING](./BUILDING.md) document.

`container` is designed to take advantage of the features of the macOS 16 Developer Preview. You can run the application on macOS Sequoia, but the `container` maintainers typically will not address Sequoia issues that cannot be reproduced on the macOS 16 Developer Preview.

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

## Next steps

- Take [a guided tour of `container`](./docs/tutorial.md) by building, running, and publishing a simple web server image.
- Learn how to [use various `container` features](./docs/how-to.md).
- Read a brief description and [technical overview](./docs/technical-overview.md) of `container`.

