//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(macOS)
import Foundation
import ContainerXPC

/// Keys for XPC fields.
public enum ImagesServiceXPCKeys: String {
    case fd
    /// FDs pointing to container logs key.
    case logs
    /// Path to a file on disk key.
    case filePath

    /// Images
    case imageReference
    case imageNewReference
    case imageDescription
    case imageDescriptions
    case filesystem
    case ociPlatform
    case insecureFlag
    case garbageCollect
    case maxConcurrentDownloads
    case forceLoad
    case rejectedMembers

    /// ContentStore
    case digest
    case digests
    case directory
    case contentPath
    case imageSize
    case ingestSessionId

    /// Disk Usage
    case activeImageReferences
    case totalCount
    case activeCount
    case reclaimableSize
}

extension XPCMessage {
    public func set(key: ImagesServiceXPCKeys, value: String) {
        self.set(key: key.rawValue, value: value)
    }

    public func set(key: ImagesServiceXPCKeys, value: UInt64) {
        self.set(key: key.rawValue, value: value)
    }

    public func set(key: ImagesServiceXPCKeys, value: Data) {
        self.set(key: key.rawValue, value: value)
    }

    public func set(key: ImagesServiceXPCKeys, value: Bool) {
        self.set(key: key.rawValue, value: value)
    }

    public func set(key: ImagesServiceXPCKeys, value: Int64) {
        self.set(key: key.rawValue, value: value)
    }

    public func string(key: ImagesServiceXPCKeys) -> String? {
        self.string(key: key.rawValue)
    }

    public func data(key: ImagesServiceXPCKeys) -> Data? {
        self.data(key: key.rawValue)
    }

    public func dataNoCopy(key: ImagesServiceXPCKeys) -> Data? {
        self.dataNoCopy(key: key.rawValue)
    }

    public func uint64(key: ImagesServiceXPCKeys) -> UInt64 {
        self.uint64(key: key.rawValue)
    }

    public func int64(key: ImagesServiceXPCKeys) -> Int64 {
        self.int64(key: key.rawValue)
    }

    public func bool(key: ImagesServiceXPCKeys) -> Bool {
        self.bool(key: key.rawValue)
    }
}

#endif
