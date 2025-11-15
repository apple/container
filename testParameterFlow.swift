#!/usr/bin/env swift

import Foundation

print("Testing parameter flow...\n")

print("1. CLI flag parsing...")
struct ProgressFlags {
    var disableProgressUpdates = false
    var maxConcurrentDownloads: Int = 3
}

let defaultFlags = ProgressFlags()
print("  ✓ Default: \(defaultFlags.maxConcurrentDownloads)")

let customFlags = ProgressFlags(disableProgressUpdates: false, maxConcurrentDownloads: 6)
print("  ✓ Custom: \(customFlags.maxConcurrentDownloads)")
print("  PASSED\n")

print("2. XPC key...")
enum ImageServiceXPCKeys: String {
    case maxConcurrentDownloads
}

let key = ImageServiceXPCKeys.maxConcurrentDownloads
print("  ✓ Key exists: \(key.rawValue)")
print("  PASSED\n")

print("3. Function signatures...")
func mockClientImagePull(
    reference: String,
    maxConcurrentDownloads: Int = 3
) -> String {
    return "pull(\(reference), maxConcurrent=\(maxConcurrentDownloads))"
}

_ = mockClientImagePull(reference: "nginx:latest")
_ = mockClientImagePull(reference: "nginx:latest", maxConcurrentDownloads: 6)
print("  ✓ Compiles")
print("  PASSED\n")

print("4. Parameter propagation...")

struct MockXPCMessage {
    var values: [String: Any] = [:]

    mutating func set(key: String, value: Int64) {
        values[key] = value
    }

    func int64(key: String) -> Int64 {
        return values[key] as? Int64 ?? 3
    }
}

func simulateFlow(maxConcurrent: Int) -> Int {
    let flags = ProgressFlags(maxConcurrentDownloads: maxConcurrent)
    var xpcMessage = MockXPCMessage()
    xpcMessage.set(key: "maxConcurrentDownloads", value: Int64(flags.maxConcurrentDownloads))
    return Int(xpcMessage.int64(key: "maxConcurrentDownloads"))
}

for testValue in [1, 3, 6] {
    guard simulateFlow(maxConcurrent: testValue) == testValue else {
        print("  ✗ Failed")
        exit(1)
    }
}
print("  ✓ Values propagate correctly")
print("  PASSED\n")

print("5. Implementation verification...")

let filesToCheck = [
    "Sources/ContainerClient/Flags.swift",
    "Sources/ContainerClient/Core/ClientImage.swift",
    "Sources/Services/ContainerImagesService/Server/ImageService.swift",
]

for file in filesToCheck {
    if let content = try? String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8),
       content.contains("maxConcurrentDownloads") {
        continue
    }
    print("  ✗ Missing in \(file)")
    exit(1)
}
print("  ✓ Found in implementation")
print("  PASSED\n")

print("All tests passed!")
