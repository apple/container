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
import Logging
import SystemPackage
import Testing

@testable import ContainerPlugin

struct ApplicationRootTests {
    @Test func defaultPathIsAbsolute() {
        #expect(ApplicationRoot.defaultPath.isAbsolute)
    }

    @Test func defaultPathEndsWithContainerComponent() {
        #expect(ApplicationRoot.defaultPath.lastComponent?.string == "com.apple.container")
    }

    @Test
    func testAppRootIsExcludedFromBackups() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let appRoot = tempDir.appendingPathComponent("test-app-root-\(UUID())")

        defer {
            try? FileManager.default.removeItem(at: appRoot)
        }

        var logger = Logger(label: "test.ApplicationRoot")
        logger.logLevel = .critical

        try ApplicationRoot.ensureCreated(at: appRoot, log: logger)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: appRoot.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue, "appRoot should be created")

        let readBack = try appRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(
            readBack.isExcludedFromBackup == true,
            "ApplicationRoot.ensureCreated should explicitly exclude appRoot from backups."
        )
    }
}

struct InstallRootTests {
    @Test func defaultPathIsAbsolute() {
        #expect(InstallRoot.defaultPath.isAbsolute)
    }

    @Test func defaultPathIsGrandparentOfExecutable() {
        #expect(InstallRoot.defaultPath == CommandLine.executablePath.removingLastComponent().removingLastComponent())
    }
}

struct LogRootTests {
    @Test func pathIsNilWhenEnvUnset() {
        // CONTAINER_LOG_ROOT is not set in the unit test environment
        #expect(LogRoot.path == nil)
    }
}
