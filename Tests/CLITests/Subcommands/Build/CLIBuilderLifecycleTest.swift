//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import Testing

extension TestCLIBuildBase {
    class CLIBuilderLifecycleTest: TestCLIBuildBase {
        override init() throws {}
        @Test func testBuilderStartStopCommand() throws {
            #expect(throws: Never.self) {
                try self.builderStart()
                try self.waitForBuilderRunning()
                let status = try self.getContainerStatus("buildkit")
                #expect(status == "running", "BuildKit container is not running")
            }
            #expect(throws: Never.self) {
                try self.builderStop()
                let status = try self.getContainerStatus("buildkit")
                #expect(status == "stopped", "BuildKit container is not stopped")
            }
        }

        @Test func testBuilderEnvironmentColors() throws {
            let testColors = "run=green:warning=yellow:error=red:cancel=cyan"
            let testNoColor = "true"

            let originalColors = ProcessInfo.processInfo.environment["BUILDKIT_COLORS"]
            let originalNoColor = ProcessInfo.processInfo.environment["NO_COLOR"]

            defer {
                if let originalColors {
                    setenv("BUILDKIT_COLORS", originalColors, 1)
                } else {
                    unsetenv("BUILDKIT_COLORS")
                }
                if let originalNoColor {
                    setenv("NO_COLOR", originalNoColor, 1)
                } else {
                    unsetenv("NO_COLOR")
                }

                try? builderStop()
                try? builderDelete(force: true)
            }

            setenv("BUILDKIT_COLORS", testColors, 1)
            setenv("NO_COLOR", testNoColor, 1)

            try? builderStop()
            try? builderDelete(force: true)

            let (_, _, err, status) = try run(arguments: ["builder", "start"])
            try #require(status == 0, "builder start failed: \(err)")

            try waitForBuilderRunning()

            let container = try inspectContainer("buildkit")
            let envVars = container.configuration.initProcess.environment

            #expect(
                envVars.contains("BUILDKIT_COLORS=\(testColors)"),
                "Expected BUILDKIT_COLORS to be passed to container, but it was missing from env: \(envVars)"
            )
            #expect(
                envVars.contains("NO_COLOR=\(testNoColor)"),
                "Expected NO_COLOR to be passed to container, but it was missing from env: \(envVars)"
            )
        }
    }
}
