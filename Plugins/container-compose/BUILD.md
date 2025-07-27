# Building and Testing Container Compose Plugin

## Prerequisites

- macOS 15 or later
- Swift 6.2 or later
- Main container project dependencies

## Building

### From the main project root:

```bash
# Build everything including the plugin
make all

# Build only the compose plugin
make plugin-compose

# Clean build
make clean
```

### From the plugin directory:

```bash
cd Plugins/container-compose

# Build in debug mode
swift build

# Build in release mode
swift build -c release

# Run the plugin directly
    .build/debug/compose --help
```

## Testing

### Run tests from plugin directory:

```bash
cd Plugins/container-compose

# Run all tests
swift test

# Run specific test
swift test --filter ComposeParserTests

# Run with verbose output
swift test --verbose
```

### Manual testing:

1. Build the plugin:
   ```bash
   swift build
   ```

2. Test basic functionality:
   ```bash
   # Validate a compose file
    .build/debug/compose validate -f test-compose.yml
   
   # Show help
    .build/debug/compose --help
    .build/debug/compose up --help
   ```

## Installation

### Via main project install:

```bash
# From main project root
make install
```

This installs the plugin to: `/usr/local/libexec/container/plugins/compose/`

### Manual installation:

```bash
# Build in release mode
cd Plugins/container-compose
swift build -c release

# Copy to plugin directory
sudo mkdir -p /usr/local/libexec/container/plugins/compose/bin
sudo cp .build/release/compose /usr/local/libexec/container/plugins/compose/bin/
sudo cp config.json /usr/local/libexec/container/plugins/compose/
```

## Integration Testing

After installation, test the plugin integration:

```bash
# Should work through main container CLI
container compose --help
container compose up --help

# Create a test compose file
cat > test-compose.yml << 'EOF'
version: '3'
services:
  web:
    image: nginx:alpine
    ports:
      - "8080:80"
EOF

# Test compose commands
container compose validate -f test-compose.yml
container compose up -d -f test-compose.yml
container compose ps -f test-compose.yml
container compose down -f test-compose.yml
```

## Troubleshooting

### Build Errors

1. **Missing dependencies**: Ensure the main container project is built first
   ```bash
   cd ../..
   swift build
   ```

2. **Swift version**: Check Swift version
   ```bash
   swift --version
   ```

3. **Clean build**: Try a clean build
   ```bash
   swift package clean
   swift build
   ```

### Runtime Errors

1. **Plugin not found**: Check installation path
   ```bash
    ls -la /usr/local/libexec/container/plugins/compose/
   ```

2. **Permission issues**: Ensure proper permissions
   ```bash
    sudo chmod +x /usr/local/libexec/container/plugins/compose/bin/compose
   ```

3. **Debug output**: Enable debug logging
   ```bash
   container compose --debug up
   ```

## Development Workflow

1. Make changes to the plugin code
2. Build and test locally:
   ```bash
   swift build && swift test
   ```
3. Test integration:
   ```bash
   make -C ../.. plugin-compose
   sudo make -C ../.. install
   container compose --help
   ```
4. Submit changes via PR

## Notes

- The plugin uses a stub for ProgressBar to avoid dependencies on internal APIs
- All compose functionality is self-contained in the plugin
- The plugin can be developed and tested independently of the main project