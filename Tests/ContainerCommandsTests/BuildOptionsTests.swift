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

import ArgumentParser
import Foundation
import Testing

@testable import ContainerCommands

struct BuildOptionsTests {
    private func withContext(dockerfile: Bool, _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("test-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if dockerfile {
            try "FROM alpine\n".write(to: directory.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        }
        defer {
            _ = chmod(directory.path, 0o755)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory)
    }

    /// The message of the error that parsing `arguments` throws, or nil when they are accepted.
    private func parseMessage(for arguments: [String]) -> String? {
        do {
            _ = try BuildOptions.parse(arguments)
            return nil
        } catch {
            return BuildOptions.message(for: error)
        }
    }

    /// The message of the error that looking for the Dockerfile throws, or nil when one is found.
    private func resolveMessage(for arguments: [String]) throws -> String? {
        let options = try BuildOptions.parse(arguments)
        do {
            _ = try options.resolveDockerfile()
            return nil
        } catch {
            return String(describing: error)
        }
    }

    @Test
    func unreadableContextIsReportedAsPermissionDenied() throws {
        try #require(geteuid() != 0, "permission checks do not apply to root")
        try withContext(dockerfile: true) { directory in
            #expect(chmod(directory.path, 0o000) == 0)
            let message = try resolveMessage(for: [directory.path])
            #expect(message?.contains("cannot read context dir") == true)
            #expect(message?.contains("permission denied") == true)
        }
    }

    @Test
    func unreadableContextWithAnExplicitDockerfileIsReportedAsPermissionDenied() throws {
        try #require(geteuid() != 0, "permission checks do not apply to root")
        try withContext(dockerfile: true) { directory in
            let dockerfile = directory.appendingPathComponent("Dockerfile").path
            #expect(chmod(directory.path, 0o000) == 0)
            let message = parseMessage(for: ["--file", dockerfile, directory.path])
            #expect(message?.contains("cannot read file") == true)
            #expect(message?.contains("permission denied") == true)
        }
    }

    @Test
    func readableContextWithoutADockerfileKeepsTheNotFoundMessage() throws {
        try withContext(dockerfile: false) { directory in
            let message = try resolveMessage(for: [directory.path])
            #expect(message?.contains("dockerfile not found in context dir") == true)
        }
    }

    @Test
    func missingExplicitDockerfileKeepsTheDoesNotExistMessage() throws {
        try withContext(dockerfile: false) { directory in
            let dockerfile = directory.appendingPathComponent("Dockerfile").path
            #expect(parseMessage(for: ["--file", dockerfile, directory.path])?.contains("file does not exist") == true)
        }
    }

    @Test
    func readableContextWithADockerfileIsAccepted() throws {
        try withContext(dockerfile: true) { directory in
            #expect(parseMessage(for: [directory.path]) == nil)
            let message = try resolveMessage(for: [directory.path])
            #expect(message == nil)
        }
    }
}
