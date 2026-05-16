//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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

import Foundation

extension FileManager {
    /// Total bytes allocated on disk for all files in a directory (recursive).
    public func allocatedSize(of directory: URL) -> UInt64 {
        guard
            let enumerator = self.enumerator(
                at: directory,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return 0
        }

        var size: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                let fileSize = resourceValues.totalFileAllocatedSize
            else {
                continue
            }
            size += UInt64(fileSize)
        }
        return size
    }
}
