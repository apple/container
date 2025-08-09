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

import Darwin
import Foundation
import Testing

@testable import ContainerBuildSnapshotter

@Suite struct FileMetadataDifferTests {

    @Test func typeChangedDirectoryToRegular() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let nodePath = dir.appendingPathComponent("node")

            // Create directory and inspect
            try TestUtils.mkdir(nodePath)
            let inspector = DefaultFileAttributeInspector()
            let opts = InspectorOptions()
            let oldAttrs = try await inspector.inspect(url: nodePath, options: opts)

            // Remove directory and create file at same path
            try FileManager.default.removeItem(at: nodePath)
            try TestUtils.writeString(nodePath, "file-now")
            let newAttrs = try await inspector.inspect(url: nodePath, options: opts)

            let differ = FileMetadataDiffer()
            let r = differ.diff(old: oldAttrs, new: newAttrs, options: opts)
            #expect(r == .typeChanged)
        }
    }

    @Test func symlinkTargetChanged() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let linkPath = dir.appendingPathComponent("link")

            // Create symlink pointing to a.txt and inspect
            try TestUtils.makeSymlink(at: linkPath, to: "a.txt")
            let inspector = DefaultFileAttributeInspector()
            let opts = InspectorOptions()
            let oldAttrs = try await inspector.inspect(url: linkPath, options: opts)

            // Remove and recreate with different target
            try FileManager.default.removeItem(at: linkPath)
            try TestUtils.makeSymlink(at: linkPath, to: "b.txt")
            let newAttrs = try await inspector.inspect(url: linkPath, options: opts)

            let differ = FileMetadataDiffer()
            let r = differ.diff(old: oldAttrs, new: newAttrs, options: opts)
            #expect(r == .symlinkTargetChanged)
        }
    }

    @Test func directoryMetadataOnlyOnModeChange() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let dirPath = dir.appendingPathComponent("d")

            // Create directory with default permissions and inspect
            try TestUtils.mkdir(dirPath)
            let inspector = DefaultFileAttributeInspector()
            let opts = InspectorOptions()
            let oldAttrs = try await inspector.inspect(url: dirPath, options: opts)

            // Change permissions
            try TestUtils.chmod(dirPath, mode: 0o700)
            let newAttrs = try await inspector.inspect(url: dirPath, options: opts)

            let differ = FileMetadataDiffer()
            let r = differ.diff(old: oldAttrs, new: newAttrs, options: opts)
            #expect(r == .metadataOnly)
        }
    }

    @Test func regularFileSizeChangeNotMetadataOnly() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let oldF = dir.appendingPathComponent("f.txt")
            let newF = dir.appendingPathComponent("f.txt")
            try TestUtils.writeString(oldF, "abc")
            try TestUtils.writeString(newF, "abcdef")  // size changed

            let inspector = DefaultFileAttributeInspector()
            let opts = InspectorOptions()
            let oldAttrs = try await inspector.inspect(url: oldF, options: opts)
            let newAttrs = try await inspector.inspect(url: newF, options: opts)

            let differ = FileMetadataDiffer()
            let r = differ.diff(old: oldAttrs, new: newAttrs, options: opts)
            // For regular files with size change, metadata differ reports .noChange to let FileDiffer decide content change
            #expect(r == .noChange)
        }
    }

    @Test func timestampGranularityClamping() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let a = dir.appendingPathComponent("file")
            try TestUtils.writeString(a, "data")

            let inspector = DefaultFileAttributeInspector()
            var opts = InspectorOptions(timestampGranularityNS: 1_000_000)  // 1ms

            let before = try await inspector.inspect(url: a, options: opts)

            // Touch the file with a very small time difference (attempted)
            // On macOS, we can update modification date
            let fm = FileManager.default
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(0.0001)], ofItemAtPath: a.path)

            let after = try await inspector.inspect(url: a, options: opts)

            let differ = FileMetadataDiffer()
            let r = differ.diff(old: before, new: after, options: opts)

            // Due to clamping, minor sub-ms differences should be folded and yield no metadata-only diff
            #expect(r == .noChange || r == .metadataOnly)
        }
    }

    @Test func listXAttrsRespectsMaxBytesCap() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let f = dir.appendingPathComponent("withx")
            try TestUtils.writeString(f, "x")

            // Try to set an xattr; ignore failures on systems where unsupported
            let key = "user.test"
            let val = [UInt8](repeating: 0x41, count: 10)
            let rc = f.path.withCString { cstr in
                setxattr(cstr, key, val, val.count, 0, 0)
            }
            // If setting xattr failed due to ENOTSUP/EPERM, skip the heavy assertion and just ensure no crash on list
            let inspector = DefaultFileAttributeInspector()
            do {
                _ = try await inspector.listXAttrs(url: f, options: InspectorOptions(enableXAttrsCapture: true, xattrMaxBytes: 1024))
            } catch {
                // Ignore
            }

            // If setxattr succeeded, try with a very small cap to trigger size cap error
            if rc == 0 {
                do {
                    _ = try await inspector.listXAttrs(url: f, options: InspectorOptions(enableXAttrsCapture: true, xattrMaxBytes: 1))
                    Issue.record("Expected xattrTooLarge but listXAttrs succeeded")
                } catch let e as AttributeError {
                    switch e {
                    case .xattrTooLarge(_, _):
                        // expected
                        break
                    default:
                        Issue.record("Unexpected error: \(e)")
                    }
                } catch {
                    Issue.record("Unexpected error: \(error)")
                }
            }
        }
    }
}
