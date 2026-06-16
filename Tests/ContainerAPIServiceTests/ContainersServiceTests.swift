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

import ContainerAPIService
import ContainerPersistence
import ContainerPlugin
import Foundation
import Logging
import Testing

struct ContainersServiceTests {

    @Test
    func testAppRootIsExcludedFromBackups() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let appRoot = tempDir.appendingPathComponent("test-app-root-\(UUID())")
        let installRoot = tempDir.appendingPathComponent("test-install-root-\(UUID())")

        defer {
            try? FileManager.default.removeItem(at: appRoot)
            try? FileManager.default.removeItem(at: installRoot)
        }

        var logger = Logger(label: "test.ContainersService")
        logger.logLevel = .critical

        let pluginLoader = try PluginLoader(
            appRoot: appRoot,
            installRoot: installRoot,
            logRoot: nil,
            pluginDirectories: [],
            pluginFactories: [],
            log: logger
        )

        let systemConfig = try await ConfigurationLoader.load()

        _ = try ContainersService(
            appRoot: appRoot,
            pluginLoader: pluginLoader,
            containerSystemConfig: systemConfig,
            log: logger
        )

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: appRoot.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue, "appRoot should be created")

        let readBack = try appRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(
            readBack.isExcludedFromBackup == true,
            "ContainersService should explicitly exclude appRoot from Time Machine backups."
        )
    }
}
