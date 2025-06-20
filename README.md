
# `container`

`container` is a tool that you can use to create and run Linux containers as lightweight virtual machines on your Mac. It's written in Swift, and optimized for Apple silicon.

The tool consumes and produces OCI-compliant container images, so you can pull and run images from any standard container registry. You can push images that you build to those registries as well, and run the images in any other OCI-compliant application.

`container` uses the [Containerization](https://github.com/apple/containerization) Swift package for low level container, image, and process management.

![introductory movie showing some basic commands](./docs/assets/landing-movie.gif)

## Get started

### Requirements

You need an Apple silicon Mac to run `container`. To build it, see the [BUILDING](./BUILDING.md) document.

`container` relies on the new features and enhancements present in the macOS 26 beta. You can run the tool on macOS 15, but the `container` maintainers typically will not address issues discovered on macOS 15 that cannot be reproduced on the macOS 26 beta.

There are [significant networking limitations](/docs/technical-overview.md#macos-15-limitations) that impact the usability of `container` on macOS 15.

### Install or upgrade

If you're upgrading, first uninstall your existing `container` while preserving your user data:

```bash
uninstall-container.sh -k
```

Download the latest signed installer package for `container` from the [GitHub release page](https://github.com/apple/container/releases).

To install the tool, double click the package file and follow the instructions. Enter your administrator password when prompted, to give the installer permission to place the installed files under `/usr/local`.

Start the system service with:

```
container system start
```

### Uninstall

Use the `uninstall-container.sh` script to remove `container` from your system. To remove your user data along with the tool, run:

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
- View the project [API documentation](https://apple.github.io/container/documentation/).

## Contributing

Contributions to `container` are welcomed and encouraged. Please see our [main contributing guide](https://github.com/apple/containerization/blob/main/CONTRIBUTING.md) for more information.

## Project Status

The container project is currently under active development. Its stability, both for consuming the project as a Swift package and the `container` tool, is only guaranteed within minor versions, such as between 0.1.1 and 0.1.2. Minor version number releases may include breaking changes until we achieve a 1.0.0 release.
