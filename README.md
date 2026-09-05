<h1>
  <img alt="Containerization logo" src="./assets/Containerization-Logo.png" width="70" valign="middle">
  &nbsp;container
</h1>

`container` is a tool that you can use to create and run Linux containers as lightweight virtual machines on your Mac. It's written in Swift, and optimized for Apple silicon.

The tool consumes and produces [OCI-compatible container images](https://github.com/opencontainers/image-spec), so you can pull and run images from any standard container registry. You can push images that you build to those registries as well, and run the images in any other OCI-compatible application.

`container` uses the [Containerization](https://github.com/apple/containerization) Swift package for low-level container, image, and process management.

![introductory movie showing some basic commands](./docs/assets/landing-movie.gif)

## Get started

### Requirements

You need a Mac with Apple silicon to run `container`. To build it, see the [BUILDING](./BUILDING.md) document.

`container` is supported on macOS 26, since it takes advantage of new features and enhancements to virtualization and networking in this release. We do not support older versions of macOS and the `container` maintainers typically will not address issues that cannot be reproduced on macOS 26.

### Initial install

Download the latest signed installer package for `container` from the [GitHub release page](https://github.com/apple/container/releases).

To install the tool, double-click the package file and follow the instructions. Enter your administrator password when prompted, to give the installer permission to place the installed files under `/usr/local`.

Start the system service with:

```bash
container system start
```

### Run your first container

```bash
container run --rm alpine echo hello
```

This pulls the `alpine` image, runs it in a lightweight Linux VM, prints `hello`, and
removes the container when it exits. See the [tutorial](./docs/tutorials/start-here.md)
for a fuller walkthrough that builds and publishes an image of your own.

### Upgrade or downgrade

For both upgrading and downgrading, you can manually download and install the signed installer package by following the steps from [initial install](#initial-install) or use the `update-container.sh` script (installed to `/usr/local/bin`).

If you're upgrading or downgrading, you must stop your existing `container`:

```bash
container system stop
```

To upgrade to the latest release, simply run the command below:

```bash
/usr/local/bin/update-container.sh
```

To downgrade, you must uninstall your existing `container` (the `-k` flag keeps your user data, while `-d` removes it):

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

- Take [a guided tour of `container`](./docs/tutorials/start-here.md) by building, running, and publishing a simple web server image.
- Learn how to [use various `container` features](./docs/how-to.md).
- Read a brief description and [technical overview](./docs/technical-overview.md) of `container`.
- Browse the [full command reference](./docs/command-reference.md).
- [Build and run](./BUILDING.md) `container` on your own development system.
- View the project [API documentation](https://apple.github.io/container/documentation/).

## Contributing

Contributions to `container` are welcome and encouraged. Please see our [main contributing guide](https://github.com/apple/containerization/blob/main/CONTRIBUTING.md) for more information.

## Project Status

The container project is under active development. Its release versions are product versions, not semantic versions.

The `container` CLI compatibility generally preserves backward compatibility within a major release (not breaking existing scripts), however, there may be the odd case where breaking compatibility may be necessary. **Note:** Features marked *experimental* (for example, the `k8s` subcommand) may change frequently and dramatically and do not guarantee backward compatibility.

The `container-apiserver` XPC API compatibility preserves forward and backward compatibility within a major version. 
Other non-public XPC helpers do not guarantee CLI or API compatibility across different versions.

The `container` application data provides forward compatibility only, guaranteed within one major version. Upgrading to a newer major version may require a specific upgrade path.
