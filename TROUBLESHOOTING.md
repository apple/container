# Troubleshooting

Known issues and workarounds. If your problem isn't listed here, check the [open issues](https://github.com/apple/container/issues) or file a new one.

## Xcode or developer tools not found

Build errors about missing compilers usually mean `xcode-select` is pointing at the Command Line Tools instead of a full Xcode installation:

```bash
xcode-select --print-path
```

If this returns `/Library/Developer/CommandLineTools`, switch it to Xcode:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

On macOS 26 you'll want the latest Xcode:

```bash
sudo xcode-select --switch /Applications/Xcode-latest.app/Contents/Developer
```

## Wrong Swift version

Swift 6.1+ is required. Check with `swift --version`.

If you have multiple toolchains, SPM picks whatever `swift` is first in `$PATH`. You can also just set `DEVELOPER_DIR` before building:

```bash
DEVELOPER_DIR=/Applications/Xcode-latest.app/Contents/Developer make all
```

## Permission errors during install

`make install` builds a `.pkg` and runs `sudo installer` to put binaries in `/usr/local`. If you don't have sudo or prefer a different location:

```bash
DEST_DIR=~/.local/ SUDO= make install
```

Don't forget to add `~/.local/bin` to your `$PATH` afterwards.

See also [#1281](https://github.com/apple/container/issues/1281) for Homebrew-specific permission issues.

## Network errors in integration tests

Integration tests spin up VMs that need outbound network access. Corporate proxies can interfere — try excluding the local ranges:

```bash
export NO_PROXY="${NO_PROXY},192.168.0.0/16,fe80::/10"
export no_proxy="${no_proxy},192.168.0.0/16,fe80::/10"
make test integration
```

VPN can also cause issues, see [#1307](https://github.com/apple/container/issues/1307).

## Kernel install hangs

The `install-kernel` target starts the container system and waits for the kernel to finish installing. If it times out:

1. Stop the system: `bin/container system stop`
2. Give launchd a few seconds to clean up
3. Try again with a longer timeout: `bin/container --debug system start --timeout 120`
4. Run `make install-kernel` again

Still stuck? Check for stale launchd services:

```bash
launchctl list | grep com.apple.container
```

You can clean these up with `scripts/ensure-container-stopped.sh -a`. See [#1280](https://github.com/apple/container/issues/1280) and [#1306](https://github.com/apple/container/issues/1306) for related issues.

## vmnet fails under ~/Documents or ~/Desktop

macOS 26 has a bug in the `vmnet` framework — network creation fails if the project or helper binaries sit under `~/Documents` or `~/Desktop`. Move the project somewhere else:

```bash
mv ~/Documents/container ~/projects/container
```

Alternatively, `make install` puts binaries in `/usr/local` which isn't affected.
