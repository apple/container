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

import ContainerizationError
import Foundation
import SystemPackage
import Testing

@testable import ContainerCommands

struct SystemStartAppRootTests {
    @Test
    func ensureWritableDirectorySucceedsForWritableParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-approot-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let child = FilePath(root.path).appending("apiserver")
        try Application.SystemStart.ensureWritableDirectory(at: child)
        #expect(FileManager.default.fileExists(atPath: child.string))
    }

    @Test
    func ensureWritableDirectoryThrowsClearErrorForReadOnlyParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-approot-ro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

        let child = FilePath(root.path).appending("apiserver")
        do {
            try Application.SystemStart.ensureWritableDirectory(at: child)
            Issue.record("expected ensureWritableDirectory to throw for a read-only app-root")
        } catch let error as ContainerizationError {
            let message = error.description
            #expect(message.contains("app-root must be writable"))
            #expect(message.contains(child.string) || message.contains("apiserver"))
        } catch {
            Issue.record("expected ContainerizationError, got \(error)")
        }
    }
}
