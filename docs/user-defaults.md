# User Defaults Configuration

The `container` CLI uses macOS user defaults to store configuration settings. These settings persist between sessions and allow you to customize the behavior of various commands.

## Viewing Current Defaults

To view a specific default value, use the macOS `defaults` command:

```bash
defaults read com.apple.container.defaults <key>
```

## Available User Defaults

### Build Settings

#### build.rosetta

Controls whether Rosetta translation is enabled during container builds. When enabled (default), allows building x86_64 images on Apple Silicon Macs.

**Default:** `true`

**Usage:**
```bash
# Disable Rosetta for builds
defaults write com.apple.container.defaults build.rosetta -bool false

# Enable Rosetta for builds (default)
defaults write com.apple.container.defaults build.rosetta -bool true

# Check current value
defaults read com.apple.container.defaults build.rosetta
```

**Note:** Disabling Rosetta will prevent building x86_64 images on Apple Silicon Macs. This setting only affects the build process and does not impact running containers.

### Image Settings

#### image.builder

Specifies the default BuildKit image used for building containers.

**Default:** `ghcr.io/apple/container-builder-shim/builder:<version>`

**Usage:**
```bash
# Set a custom builder image
defaults write com.apple.container.defaults image.builder "my-registry.com/my-builder:latest"

# Reset to default
defaults delete com.apple.container.defaults image.builder
```

#### image.init

Specifies the default init image used for container initialization.

**Default:** `ghcr.io/apple/containerization/vminit:<version>`

**Usage:**
```bash
# Set a custom init image
defaults write com.apple.container.defaults image.init "my-registry.com/my-init:latest"
```

### Network Settings

#### dns.domain

Sets the default local DNS domain for containers.

**Default:** `test`

**Usage:**
```bash
# Set a custom DNS domain
defaults write com.apple.container.defaults dns.domain "mycompany.local"

# Alternatively, use the container CLI
container system dns default set mycompany.local
```

### Registry Settings

#### registry.domain

Sets the default registry domain for pulling images.

**Default:** `docker.io`

**Usage:**
```bash
# Set a custom default registry
defaults write com.apple.container.defaults registry.domain "ghcr.io"

# Alternatively, use the container CLI
container registry default set ghcr.io
```

### Kernel Settings

#### kernel.url

URL for downloading the default kernel used by containers.

**Default:** `https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz`

**Usage:**
```bash
# Set a custom kernel URL
defaults write com.apple.container.defaults kernel.url "https://myserver.com/custom-kernel.tar.xz"
```

#### kernel.binaryPath

Path within the kernel archive to the actual kernel binary.

**Default:** `opt/kata/share/kata-containers/vmlinux-6.12.28-153`

**Usage:**
```bash
# Set a custom kernel binary path
defaults write com.apple.container.defaults kernel.binaryPath "path/to/vmlinux"
```

## Resetting Defaults

To reset a specific setting to its default value:

```bash
defaults delete com.apple.container.defaults <key>
```

To reset all container defaults:

```bash
defaults delete com.apple.container.defaults
```

## Platform-Specific Settings

### macOS 15 Network Configuration

On macOS 15, if you experience network connectivity issues, you may need to manually configure the network subnet:

```bash
defaults write com.apple.container.defaults network.subnet 192.168.66.1/24
```

See the [technical overview](technical-overview.md#macos-15-limitations) for more details about macOS 15 limitations.