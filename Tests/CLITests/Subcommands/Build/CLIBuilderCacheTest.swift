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
    class CLIBuilderCacheTest: TestCLIBuildBase {
        override init() throws {
            try super.init()
        }

        deinit {
            try? builderDelete(force: true)
        }

        @Test func testConsecutiveBuildsDetectChanges() throws {
            let tempDir: URL = try createTempDir()
            let imageName = "registry.local/cache-test:\(UUID().uuidString)"
            let containerName = "cache-test-\(UUID().uuidString)"

            let dockerfile1 =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                RUN echo "Hello World" > /output.txt
                CMD cat /output.txt
                """
            try createContext(tempDir: tempDir, dockerfile: dockerfile1)
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")

            try self.doLongRun(name: containerName, image: imageName)
            defer {
                try? self.doStop(name: containerName)
                try? self.doDelete(name: containerName)
            }
            var output1 = try doExec(name: containerName, cmd: ["cat", "/output.txt"])
            output1 = output1.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output1 == "Hello World", "expected first build output to be 'Hello World', got '\(output1)'")

            try self.doStop(name: containerName)
            try self.doDelete(name: containerName)

            sleep(2)

            let dockerfile2 =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                RUN echo "Hello World 2" > /output.txt
                CMD cat /output.txt
                """
            try createContext(tempDir: tempDir, dockerfile: dockerfile2)
            try self.build(tag: imageName, tempDir: tempDir)

            try self.doLongRun(name: containerName, image: imageName)
            var output2 = try doExec(name: containerName, cmd: ["cat", "/output.txt"])
            output2 = output2.trimmingCharacters(in: .whitespacesAndNewlines)

            #expect(
                output2 == "Hello World 2",
                "expected second build to detect changes and output 'Hello World 2', got '\(output2)'. This indicates BuildKit is using stale cached context (issue #1143)."
            )

            try self.doStop(name: containerName)
            try self.doDelete(name: containerName)
        }

        /// Test that modifying context files (not Dockerfile) is also detected
        @Test func testConsecutiveBuildsDetectContextFileChanges() throws {
            let tempDir: URL = try createTempDir()
            let imageName = "registry.local/context-cache-test:\(UUID().uuidString)"
            let containerName = "context-cache-test-\(UUID().uuidString)"

            let dockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                COPY data.txt /data.txt
                CMD cat /data.txt
                """
            let context1: [FileSystemEntry] = [
                .file("data.txt", content: .data("Version 1".data(using: .utf8)!)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context1)
            try self.build(tag: imageName, tempDir: tempDir)

            try self.doLongRun(name: containerName, image: imageName)
            defer {
                try? self.doStop(name: containerName)
                try? self.doDelete(name: containerName)
            }
            var output1 = try doExec(name: containerName, cmd: ["cat", "/data.txt"])
            output1 = output1.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output1 == "Version 1", "expected first build to contain 'Version 1', got '\(output1)'")

            try self.doStop(name: containerName)
            try self.doDelete(name: containerName)

            sleep(2)

            let context2: [FileSystemEntry] = [
                .file("data.txt", content: .data("Version 2".data(using: .utf8)!)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context2)
            try self.build(tag: imageName, tempDir: tempDir)

            try self.doLongRun(name: containerName, image: imageName)
            var output2 = try doExec(name: containerName, cmd: ["cat", "/data.txt"])
            output2 = output2.trimmingCharacters(in: .whitespacesAndNewlines)

            #expect(
                output2 == "Version 2",
                "expected second build to detect file changes and contain 'Version 2', got '\(output2)'. BuildKit may be using stale cached context."
            )

            try self.doStop(name: containerName)
            try self.doDelete(name: containerName)
        }
    }
}
