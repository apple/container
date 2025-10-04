## Title
Support parallel layer downloads during image pull

## Description

### Problem
Currently, `container pull` downloads image layers sequentially, which can significantly increase pull times for images with many layers compared to Docker's parallel download approach.

### Proposed Enhancement
Implement concurrent layer downloads similar to Docker's behavior, where multiple layers are fetched simultaneously with configurable concurrency limits.

### Current Behavior
```swift
// Sources/ContainerClient/Core/ClientImage.swift:223-249
// Single XPC request handles entire pull sequentially
let response = try await client.send(request)
```

The `ProgressTaskCoordinator` tracks only one `currentTask` at a time:
```swift
// Sources/TerminalProgress/ProgressTaskCoordinator.swift:42-43
public actor ProgressTaskCoordinator {
    var currentTask: ProgressTask?
```

### Expected Behavior
- Download multiple layers concurrently (e.g., 3-6 concurrent downloads)
- Aggregate progress updates from multiple download tasks
- Add `--max-concurrent-downloads` flag (default: 3)
- Maintain per-layer progress visibility in terminal output

### Benefits
- Faster image pulls, especially for large multi-layer images
- Better utilization of available network bandwidth
- Improved user experience with competitive performance vs Docker

### Example
```bash
# Docker's parallel download output for reference
$ docker pull nginx:latest
latest: Pulling from library/nginx
a2abf6c4d29d: Downloading [==>        ] 1.5MB/31.4MB
a9edb18cadd1: Downloading [=====>     ] 2.1MB/25.3MB
589b7251471a: Downloading [====>      ] 1.8MB/22.1MB
...
```

### Implementation Considerations
- Maintain backward compatibility with existing progress tracking
- Handle network errors gracefully per layer
- Consider memory implications of concurrent decompression
- Respect registry rate limits
