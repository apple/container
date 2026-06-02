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

import ContainerTestSupport
import Foundation
import SystemPackage
import Testing

@testable import ContainerPersistence

struct FilePathSymlinksTests {
    @Test func realPathReturnsAbsolutePath() throws {
        let resolved = try FilePath("/tmp").resolvingSymlinks()
        #expect(resolved.isAbsolute)
    }

    @Test func symlinkResolvesToTarget() async throws {
        try await TemporaryStorage.withTempDir { dir in
            let target = dir.appending(FilePath.Component("target"))
            let link = dir.appending(FilePath.Component("link"))
            try "content".write(toFile: target.string, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(atPath: link.string, withDestinationPath: target.string)

            #expect(try link.resolvingSymlinks() == target.resolvingSymlinks())
        }
    }

    @Test func nonExistentPathThrows() {
        #expect(throws: Errno.noSuchFileOrDirectory) {
            try FilePath("/nonexistent/path/that/does/not/exist").resolvingSymlinks()
        }
    }

    @Test func relativePathResolvesToAbsolute() throws {
        let resolved = try FilePath(".").resolvingSymlinks()
        #expect(resolved.isAbsolute)
    }
}
