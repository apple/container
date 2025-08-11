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

import Crypto
import Foundation

public enum FileContentDiffResult: Equatable {
    case attributeOnly
    case contentChanged
}

/// Compares regular file byte content using a ContentHasher.
/// Notes:
/// - For symlinks and special files, treat as attribute-only; symlink target comparison is metadata.
/// - If either URL is nil (addition or deletion), treat as contentChanged.
public struct FileContentDiffer: Sendable {
    private let hasher: any ContentHasher

    public init(hasher: any ContentHasher = SHA256ContentHasher()) {
        self.hasher = hasher
    }

    public func diff(oldURL: URL?, newURL: URL?, attributesOnly: Bool = false) throws -> FileContentDiffResult {
        if attributesOnly { return .attributeOnly }
        guard let lhs = oldURL, let rhs = newURL else { return .contentChanged }
        let a = try hasher.hash(fileURL: lhs)
        let b = try hasher.hash(fileURL: rhs)
        return a == b ? .attributeOnly : .contentChanged
    }
}

public struct SHA256ContentHasher: ContentHasher {

    public init() {}

    public func hash(fileURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 4 * 1024 * 1024  // 4 MB

        while true {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        return Data(digest)
    }
}
