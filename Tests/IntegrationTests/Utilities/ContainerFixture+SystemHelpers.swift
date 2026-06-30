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

// MARK: - System helpers

extension ContainerFixture {
    /// Creates a temporary directory under ``testDir``, passes its `URL` to `body`,
    /// then removes it when `body` exits (cleanup handled by the fixture scope).
    func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = URL(filePath: testDir.appending(UUID().uuidString).string)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try await body(dir)
    }
}
