# Container Compose Plugin

This plugin provides docker-compose functionality for Apple Container, allowing you to define and run multi-container applications using familiar docker-compose YAML syntax.

## Building

From the plugin directory:
```bash
swift build
```

From the main project root:
```bash
make plugin-compose
```

## Installation

The plugin is automatically installed when you build and install the main container project:
```bash
make install
```

The plugin will be installed to:
```
/usr/local/libexec/container/plugins/container-compose/
```

## Usage

Once installed, the plugin integrates seamlessly with the container CLI:
```bash
container compose up
container compose down
container compose ps
# etc.
```

## Documentation

See COMPOSE.md for detailed documentation on supported features and usage.

## Development

The plugin follows the standard Apple Container plugin architecture:
- `config.json` - Plugin metadata and configuration
- `Sources/CLI/` - Command-line interface implementation
- `Sources/Core/` - Core compose functionality (parser, orchestrator, etc.)
- `Tests/` - Unit and integration tests

## Testing

Run tests from the plugin directory:
```bash
swift test
```