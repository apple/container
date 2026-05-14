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

import SystemPackage
import Testing

@testable import ContainerPlugin

struct ApplicationRootTests {
    private static let cwd = FilePath("/current/dir")

    @Test func defaultWhenEnvUnset() {
        #expect(ApplicationRoot.resolve(nil, currentDirectory: Self.cwd) == ApplicationRoot.defaultPath)
    }

    @Test func defaultWhenEnvEmpty() {
        #expect(ApplicationRoot.resolve("", currentDirectory: Self.cwd) == ApplicationRoot.defaultPath)
    }

    @Test func absoluteEnvReturnedAsIs() {
        #expect(ApplicationRoot.resolve("/custom/root", currentDirectory: Self.cwd) == FilePath("/custom/root"))
    }

    @Test func relativeEnvPrependsCurrentDirectory() {
        #expect(ApplicationRoot.resolve("data", currentDirectory: Self.cwd) == FilePath("/current/dir/data"))
    }

    @Test func relativeEnvWithDotDotPrependsCurrentDirectory() {
        #expect(ApplicationRoot.resolve("../sibling", currentDirectory: Self.cwd) == FilePath("/current/dir/../sibling"))
    }

    @Test func defaultPathIsAbsolute() {
        #expect(ApplicationRoot.defaultPath.isAbsolute)
    }

    @Test func defaultPathEndsWithContainerComponent() {
        #expect(ApplicationRoot.defaultPath.lastComponent?.string == "com.apple.container")
    }
}

struct InstallRootTests {
    private static let cwd = FilePath("/current/dir")

    @Test func defaultWhenEnvUnset() {
        #expect(InstallRoot.resolve(nil, currentDirectory: Self.cwd) == InstallRoot.defaultPath)
    }

    @Test func defaultWhenEnvEmpty() {
        #expect(InstallRoot.resolve("", currentDirectory: Self.cwd) == InstallRoot.defaultPath)
    }

    @Test func absoluteEnvReturnedAsIs() {
        #expect(InstallRoot.resolve("/usr/local", currentDirectory: Self.cwd) == FilePath("/usr/local"))
    }

    @Test func relativeEnvPrependsCurrentDirectory() {
        #expect(InstallRoot.resolve("local", currentDirectory: Self.cwd) == FilePath("/current/dir/local"))
    }

    @Test func defaultPathIsAbsolute() {
        #expect(InstallRoot.defaultPath.isAbsolute)
    }
}

struct LogRootTests {
    private static let cwd = FilePath("/current/dir")

    @Test func nilWhenEnvUnset() {
        #expect(LogRoot.resolve(nil, currentDirectory: Self.cwd) == nil)
    }

    @Test func nilWhenEnvEmpty() {
        #expect(LogRoot.resolve("", currentDirectory: Self.cwd) == nil)
    }

    @Test func absoluteEnvReturnedAsIs() {
        #expect(LogRoot.resolve("/var/log/container", currentDirectory: Self.cwd) == FilePath("/var/log/container"))
    }

    @Test func relativeEnvPrependsCurrentDirectory() {
        #expect(LogRoot.resolve("logs", currentDirectory: Self.cwd) == FilePath("/current/dir/logs"))
    }
}
