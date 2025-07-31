//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import ContainerBuildIR
import Foundation

/// An error related to cache operations.
public enum CacheError: Error, LocalizedError {
    /// A cache entry was expected but not found. This is often a normal cache miss.
    case itemNotFound(key: String)

    /// The manifest file for the cache is corrupted or unreadable.
    case manifestUnreadable(path: String, underlyingError: Error)

    /// A file was read from the cache, but its content hash did not match the expected digest.
    case digestMismatch(expected: Digest, actual: Digest)

    /// An error occurred while trying to write an item to the cache storage.
    case storageFailed(path: String, underlyingError: Error)

    /// Failed to encode cache-related data as UTF-8.
    case encodingFailed(String)

    // MARK: - LocalizedError Conformance

    public var errorDescription: String? {
        switch self {
        case .itemNotFound(let key):
            return "Item with key '\(key)' not found in cache."
        case .manifestUnreadable(let path, _):
            return "Failed to read cache manifest at '\(path)'."
        case .digestMismatch(let expected, let actual):
            return "Cache integrity check failed: content digest \(actual) does not match expected digest \(expected)."
        case .storageFailed(let path, _):
            return "Failed to write to cache storage at '\(path)'."
        case .encodingFailed(let details):
            return "Failed to encode cache data: \(details)"
        }
    }
}
