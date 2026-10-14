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
    @Test func defaultPathIsAbsolute() {
        #expect(ApplicationRoot.defaultPath.isAbsolute)
    }

    @Test func defaultPathEndsWithContainerComponent() {
        #expect(ApplicationRoot.defaultPath.lastComponent?.string == "com.apple.container")
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
