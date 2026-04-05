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
import Testing

final class TestCLICompose: CLITest {
    @Test
    func testComposeUpDoesNotTriggerParsableInitializationError() async throws {
        try doPull(imageName: alpine)

        try await withTempDir { directory in
            let projectName = testName.lowercased()
            let composeURL = directory.appendingPathComponent("compose.yaml")
            try """
            name: \(projectName)
            services:
              web:
                image: \(alpine)
                command: ["sleep", "infinity"]
            """.write(to: composeURL, atomically: true, encoding: .utf8)

            defer {
                _ = try? run(arguments: ["compose", "down"], currentDirectory: directory)
            }

            let (_, _, error, status) = try run(arguments: ["compose", "up"], currentDirectory: directory)
            #expect(status == 0, "expected compose up to succeed, stderr: \(error)")
            #expect(!error.contains("Can't read a value from a parsable"), "unexpected parser initialization error: \(error)")

            try waitForContainerRunning("\(projectName)-web")
        }
    }

    @Test
    func testComposeServicesResolveByServiceName() async throws {
        try doPull(imageName: alpine)

        try await withTempDir { directory in
            let projectName = testName.lowercased()
            let composeURL = directory.appendingPathComponent("compose.yaml")
            try """
            name: \(projectName)
            services:
              web:
                image: \(alpine)
                command: ["sleep", "infinity"]
              probe:
                image: \(alpine)
                depends_on:
                  web:
                    condition: service_started
                entrypoint: /bin/sh -c "nslookup web"
            """.write(to: composeURL, atomically: true, encoding: .utf8)

            defer {
                _ = try? run(arguments: ["compose", "down"], currentDirectory: directory)
            }

            let (_, _, error, status) = try run(arguments: ["compose", "up"], currentDirectory: directory)
            #expect(status == 0, "expected compose up to succeed, stderr: \(error)")

            try waitForContainerRunning("\(projectName)-web")

            let (_, output, logError, logStatus) = try run(arguments: ["logs", "\(projectName)-probe"])
            #expect(logStatus == 0, "expected probe logs to be readable, stderr: \(logError)")
            #expect(output.contains("Name:") || output.contains("Address:"), "expected service-name DNS resolution in probe logs, got: \(output)")
        }
    }
}
