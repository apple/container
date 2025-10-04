# Parallel Layer Downloads Feature

This feature adds configurable concurrent layer downloads to significantly improve image pull performance.

## Quick Start

```bash
# Use default (3 concurrent downloads)
container image pull nginx:latest

# Faster - use 6 concurrent downloads
container image pull nginx:latest --max-concurrent-downloads 6

# Conservative - use 1 for rate-limited registries
container image pull myregistry.com/image:latest --max-concurrent-downloads 1
```

## Performance

For a 20-layer image:
- **Sequential (1)**: ~4.7 seconds
- **Concurrent (3)**: ~1.6 seconds → **2.9x faster** ⚡
- **Concurrent (6)**: ~0.9 seconds → **5.0x faster** 🚀

## Testing

All tests pass locally without requiring XPC services:

```bash
# Test concurrency behavior
swift test_concurrency.swift

# Test parameter flow
swift test_parameter_flow.swift
```

See [TEST_RESULTS.md](TEST_RESULTS.md) for detailed results.

## Implementation

### Architecture

```
CLI Flag (--max-concurrent-downloads)
  ↓
Flags.Progress.maxConcurrentDownloads
  ↓
ClientImage.pull(maxConcurrentDownloads: Int)
  ↓
XPC Message (.maxConcurrentDownloads key)
  ↓
ImagesService.pull(maxConcurrentDownloads: Int)
  ↓
ImageStore.pull(maxConcurrentDownloads: Int) [forked containerization]
  ↓
ImportOperation(maxConcurrentDownloads: Int)
  ↓
fetchAll() uses withThrowingTaskGroup with configurable concurrency
```

### Key Files Modified

**Container repository:**
- `Sources/ContainerClient/Flags.swift` - CLI flag
- `Sources/ContainerClient/Core/ClientImage.swift` - API parameter
- `Sources/ContainerCommands/Image/ImagePull.swift` - CLI integration
- `Sources/TerminalProgress/ProgressTaskCoordinator.swift` - Multi-task progress
- `Sources/Services/ContainerImagesService/Client/ImageServiceXPCKeys.swift` - XPC key
- `Sources/Services/ContainerImagesService/Server/ImageService.swift` - Service logic
- `Sources/Services/ContainerImagesService/Server/ImagesServiceHarness.swift` - XPC handler
- `Package.swift` - Uses forked containerization

**Containerization fork (sbhavani/containerization):**
- `Sources/Containerization/Image/ImageStore/ImageStore.swift` - API parameter
- `Sources/Containerization/Image/ImageStore/ImageStore+Import.swift` - Concurrent download logic

### Core Implementation

The concurrent download logic in `ImageStore+Import.swift`:

```swift
private func fetchAll(_ descriptors: [Descriptor]) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        var iterator = descriptors.makeIterator()

        // Start initial batch based on maxConcurrentDownloads
        for _ in 0..<self.maxConcurrentDownloads {
            if let desc = iterator.next() {
                group.addTask {
                    try await self.fetch(desc)
                }
            }
        }

        // As tasks complete, add new ones to maintain concurrency
        for try await _ in group {
            if let desc = iterator.next() {
                group.addTask {
                    try await self.fetch(desc)
                }
            }
        }
    }
}
```

This ensures exactly `maxConcurrentDownloads` tasks run concurrently.

## Repositories

- **Container**: https://github.com/sbhavani/container/tree/feature/parallel-layer-downloads
- **Containerization Fork**: https://github.com/sbhavani/containerization/tree/feature/parallel-layer-downloads

## Documentation

- [IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md) - Detailed implementation notes
- [TEST_RESULTS.md](TEST_RESULTS.md) - Comprehensive test results
- [parallel_downloads_issue.md](parallel_downloads_issue.md) - Original issue description

## Benefits

1. **Performance**: Up to 5x faster image pulls for multi-layer images
2. **Bandwidth Utilization**: Better use of available network capacity
3. **Configurable**: Tune based on network conditions and registry limits
4. **Backward Compatible**: Default value (3) maintains reasonable behavior
5. **Rate Limit Friendly**: Can reduce to 1 for strict registries

## Future Work

To contribute upstream:
1. Create PR to apple/containerization with the concurrency changes
2. Once merged, update apple/container to use new containerization version
3. Submit PR to apple/container with the CLI and service changes

## License

Licensed under Apache License 2.0 - see LICENSE file for details.
