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

import Testing
import Foundation
import CLITests

class TestCLIComposeRm: CLITest {
    @Test func testRmHelp() throws {
        let name = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        defer { cleanup() }

        let output = try run(arguments: ["compose", "rm", "--help"])
        #expect(output.contains("Remove stopped containers"))
        #expect(output.contains("-f, --force"))
    }

    @Test func testRmNoContainers() throws {
        let name = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        defer { cleanup() }

        // Create a simple compose file
        let composeFile = createComposeFile(name: name, content: """
            services:
              test:
                image: alpine:latest
                command: ["sleep", "infinity"]
            """)

        let output = try run(arguments: ["compose", "-f", composeFile.path, "rm"])
        #expect(output.contains("No containers to remove"))
    }
}