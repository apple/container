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

import ContainerPersistence
import Foundation
import SystemPackage
import TOML

// MARK: - System helpers

extension ContainerFixture {

    /// Returns the decoded system configuration from `container system property list`.
    public func getSystemConfig() throws -> ContainerSystemConfig {
        let result = try run(["system", "property", "list", "--format", "toml"]).check()
        return try TOMLDecoder().decode(ContainerSystemConfig.self, from: Data(result.output.utf8))
    }

    /// Creates a temporary directory, calls `body` with its URL, then removes it
    /// regardless of whether `body` throws.
    public func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }
}
