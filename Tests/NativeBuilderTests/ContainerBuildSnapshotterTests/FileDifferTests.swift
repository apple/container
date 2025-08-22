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

import ContainerBuildIR
import Foundation
import Testing

@testable import ContainerBuildSnapshotter

@Suite struct FileDifferTests {

    @Test func regularFileMetadataOnlyOnModeChange() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let a = dir.appendingPathComponent("file.txt")
            try TestUtils.writeString(a, "same", permissions: 0o644)

            // Capture old/new attrs with same content, same size, same mtime but different mode.
            let inspector = DefaultFileAttributeInspector()
            let opts = InspectorOptions()

            // Read initial
            let oldAttrs = try await inspector.inspect(url: a, options: opts)

            // Change permissions; mtime typically unchanged when only chmod
            try TestUtils.chmod(a, mode: 0o600)
            let newAttrs = try await inspector.inspect(url: a, options: opts)

            let differ = FileDiffer()
            let r = try differ.diff(
                oldAttrs: oldAttrs,
                newAttrs: newAttrs,
                oldURL: a,
                newURL: a,
                options: opts
            )
            #expect(r == .metadataOnly)
        }
    }

    @Test func regularFileContentChangedSameSize() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let oldURL = dir.appendingPathComponent("f1.txt")
            let newURL = dir.appendingPathComponent("f2.txt")

            // Same size, different content
            try TestUtils.write(oldURL, contents: Data([0x41, 0x41, 0x41, 0x41]))  // AAAA
            try TestUtils.write(newURL, contents: Data([0x41, 0x41, 0x41, 0x42]))  // AAAB

            let inspector = DefaultFileAttributeInspector()
            let opts = InspectorOptions()

            let oldAttrs = try await inspector.inspect(url: oldURL, options: opts)
            // Tweak mtime by re-writing the new file to ensure mtime differs and triggers hashing
            try TestUtils.write(newURL, contents: Data([0x41, 0x41, 0x41, 0x42]))
            let newAttrs = try await inspector.inspect(url: newURL, options: opts)

            let differ = FileDiffer()
            let r = try differ.diff(
                oldAttrs: oldAttrs,
                newAttrs: newAttrs,
                oldURL: oldURL,
                newURL: newURL,
                options: opts
            )
            #expect(r == .contentChanged)
        }
    }

    @Test func directoryMetadataOnlyPropagates() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let dirPath = dir.appendingPathComponent("dir")
            try TestUtils.mkdir(dirPath)

            let inspector = DefaultFileAttributeInspector()
            let opts = InspectorOptions()

            // Capture attributes BEFORE changing mode
            let oldAttrs = try await inspector.inspect(url: dirPath, options: opts)

            // Now change permissions
            try TestUtils.chmod(dirPath, mode: 0o700)

            // Capture attributes AFTER changing mode
            let newAttrs = try await inspector.inspect(url: dirPath, options: opts)

            let differ = FileDiffer()
            let r = try differ.diff(
                oldAttrs: oldAttrs,
                newAttrs: newAttrs,
                oldURL: dirPath,
                newURL: dirPath,
                options: opts
            )
            #expect(r == .metadataOnly)
        }
    }

    @Test func symlinkTargetChangedPropagates() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let linkPath = dir.appendingPathComponent("link")

            // Create symlink pointing to "a"
            try TestUtils.makeSymlink(at: linkPath, to: "a")

            let inspector = DefaultFileAttributeInspector()
            let opts = InspectorOptions()

            // Capture attributes with target "a"
            let oldAttrs = try await inspector.inspect(url: linkPath, options: opts)

            // Remove and recreate with different target
            try FileManager.default.removeItem(at: linkPath)
            try TestUtils.makeSymlink(at: linkPath, to: "b")

            // Capture attributes with target "b"
            let newAttrs = try await inspector.inspect(url: linkPath, options: opts)

            let differ = FileDiffer()
            let r = try differ.diff(
                oldAttrs: oldAttrs,
                newAttrs: newAttrs,
                oldURL: linkPath,
                newURL: linkPath,
                options: opts
            )
            #expect(r == .symlinkTargetChanged)
        }
    }

    @Test func noChangeWhenIdentical() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let a = dir.appendingPathComponent("t.txt")
            try TestUtils.writeString(a, "x", permissions: 0o644)

            let inspector = DefaultFileAttributeInspector()
            let opts = InspectorOptions()
            let oldAttrs = try await inspector.inspect(url: a, options: opts)
            let newAttrs = try await inspector.inspect(url: a, options: opts)

            let differ = FileDiffer()
            let r = try differ.diff(
                oldAttrs: oldAttrs,
                newAttrs: newAttrs,
                oldURL: a,
                newURL: a,
                options: opts
            )
            #expect(r == nil)
        }
    }
}
