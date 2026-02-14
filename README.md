# `container`

`container` is a tool that you can use to create and run Linux containers as lightweight virtual machines on your Mac. It's written in Swift, and optimized for Apple silicon.

The tool consumes and produces [OCI-compatible container images](https://github.com/opencontainers/image-spec), so you can pull and run images from any standard container registry. You can push images that you build to those registries as well, and run the images in any other OCI-compatible application.

`container` uses the [Containerization](https://github.com/apple/containerization) Swift package for low level container, image, and process management.

![introductory movie showing some basic commands](./docs/assets/landing-movie.gif)

## Get started

### Requirements

You need a Mac with Apple silicon to run `container`. To build it, see the [BUILDING](./BUILDING.md) document.

`container` is supported on macOS 26, since it takes advantage of new features and enhancements to virtualization and networking in this release. We do not support older versions of macOS and the `container` maintainers typically will not address issues that cannot be reproduced on the macOS 26.

### Initial install

Download the latest signed installer package for `container` from the [GitHub release page](https://github.com/apple/container/releases).

To install the tool, double-click the package file and follow the instructions. Enter your administrator password when prompted, to give the installer permission to place the installed files under `/usr/local`.

Start the system service with:

```bash
container system start
```

### Upgrade or downgrade

For both upgrading and downgrading, you can manually download and install the signed installer package by following the steps from [initial install](#initial-install) or use the `update-container..sh` script (installed to `/usr/local/bin`).

If you're upgrading and downgrading, you must stop your existing `container`:

```bash
container system stop
```

For upgrading to the latest release version, simply run the command below:

```bash
/usr/local/bin/update-container.sh
```

If you're downgrading, you must uninstall your existing `container` (the `-k` flag keeps your user data, while `-d` removes it):

```bash
/usr/local/bin/uninstall-container.sh -k
/usr/local/bin/update-container.sh -v 0.3.0
```

Start the system service with:

```bash
container system start
```

### Uninstall

Use the `uninstall-container.sh` script (installed to `/usr/local/bin`) to remove `container` from your system. To remove your user data along with the tool, run:

```bash
/usr/local/bin/uninstall-container.sh -d
```

To retain your user data so that it is available should you reinstall later, run:

```bash
/usr/local/bin/uninstall-container.sh -k
```

## Next steps

- Take [a guided tour of `container`](./docs/tutorial.md) by building, running, and publishing a simple web server image.
- Learn how to [use various `container` features](./docs/how-to.md).
- Read a brief description and [technical overview](./docs/technical-overview.md) of `container`.
- Browse the [full command reference](./docs/command-reference.md).
- [Build and run](./BUILDING.md) `container` on your own development system.
- View the project [API documentation](https://apple.github.io/container/documentation/).

## Contributing

Contributions to `container` are welcomed and encouraged. Please see our [main contributing guide](https://github.com/apple/containerization/blob/main/CONTRIBUTING.md) for more information.

## Project Status

The container project is currently under active development. Its stability, both for consuming the project as a Swift package and the `container` tool, is only guaranteed within patch versions, such as between 0.1.1 and 0.1.2. Minor version number releases may include breaking changes until we achieve a 1.0.0 release.
