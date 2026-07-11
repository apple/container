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

import ContainerAPIClient
import Foundation
import Testing

@testable import ContainerCommands

struct ApplicationPluginDiscoveryTests {
    @Test
    func helpPluginDiscoveryUsesShortHealthDeadline() async throws {
        let appRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appRoot) }

        let loader = await Application.pluginLoaderForHelp { timeout in
            #expect(timeout == .seconds(1))
            return try Self.makeSystemHealth(appRoot: appRoot)
        }

        #expect(loader != nil)
    }

    @Test
    func helpPluginDiscoveryReturnsNilWhenHealthCheckFails() async {
        let loader = await Application.pluginLoaderForHelp { timeout in
            #expect(timeout == .seconds(1))
            throw TestFailure.unavailable
        }

        #expect(loader == nil)
    }

    private static func makeSystemHealth(appRoot: URL) throws -> SystemHealth {
        let json = """
            {
                "appRoot": "\(appRoot.absoluteString)",
                "installRoot": "file:///tmp/container-test-install-root",
                "apiServerVersion": "test-version",
                "apiServerCommit": "test-commit",
                "apiServerBuild": "debug",
                "apiServerAppName": "container-apiserver"
            }
            """
        return try JSONDecoder().decode(SystemHealth.self, from: Data(json.utf8))
    }
}

private enum TestFailure: Error {
    case unavailable
}
