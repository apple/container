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
import Darwin
import Foundation
import Testing

@testable import ContainerBuildSnapshotter

@Suite struct DiffKeyBinaryEncodingTests {

    // Helper function to compute DiffKey using DirectoryDiffer first
    private func computeDiffKey(
        baseDigest: ContainerBuildIR.Digest? = nil,
        baseMount: URL? = nil,
        targetMount: URL,
        hasher: any ContentHasher = SHA256ContentHasher(),
        inspectorOptions: InspectorOptions = InspectorOptions(),
        coupleToBase: Bool = true
    ) async throws -> DiffKey {
        let directoryDiffer = DirectoryDiffer.makeDefault(
            hasher: hasher,
            options: inspectorOptions
        )

        let changes = try await directoryDiffer.diff(base: baseMount, target: targetMount)

        return try await DiffKey.computeFromDiffs(
            changes,
            baseDigest: baseDigest,
            baseMount: baseMount,
            targetMount: targetMount,
            hasher: hasher,
            coupleToBase: coupleToBase
        )
    }

    // Helper to set an xattr safely; returns true if set succeeded
    private func setXAttr(_ url: URL, name: String, value: Data) -> Bool {
        let path = url.path
        let result = name.withCString { namePtr in
            value.withUnsafeBytes { valPtr in
                setxattr(path, namePtr, valPtr.baseAddress, value.count, 0, 0)
            }
        }
        return result == 0
    }

    // MARK: a) Filenames with special chars, unicode, spaces, newline, long names
    @Test func filenamesWithSpecialCharactersProduceDistinctKeys() async throws {
        try await TestUtils.withTempDirAsync { root in
            let cases: [String] = [
                "foo|bar",
                " leading-and-trailing-space ",
                "line\nbreak",
                "aπb|c",
                // Long but within common filesystem component limits (<=255 bytes)
                String(repeating: "a", count: 250),
                String(repeating: "b", count: 251),
            ]

            var keys: [String: DiffKey] = [:]
            for (idx, name) in cases.enumerated() {
                let dir = root.appendingPathComponent("case\(idx)", isDirectory: true)
                try TestUtils.mkdir(dir)
                let file = dir.appendingPathComponent(name)
                try TestUtils.writeString(file, "data-\(idx)")

                let k = try await computeDiffKey(targetMount: dir)
                keys[name] = k
                #expect(k.stringValue.hasPrefix("sha256:"))
            }

            // Ensure all produced keys are distinct across cases
            #expect(Set(keys.values).count == keys.count)
        }
    }

    // MARK: b) XAttrs hashing determinism and order independence (with '|' and newline in values)
    @Test func xattrsDeterministicAndOrderIndependent() async throws {
        try await TestUtils.withTempDirAsync { root in
            let t1 = root.appendingPathComponent("t1", isDirectory: true)
            let t2 = root.appendingPathComponent("t2", isDirectory: true)
            try TestUtils.mkdir(t1)
            try TestUtils.mkdir(t2)

            let f1 = t1.appendingPathComponent("file")
            let f2 = t2.appendingPathComponent("file")
            try TestUtils.writeString(f1, "same")
            try TestUtils.writeString(f2, "same")

            // Candidate keys (some may be rejected by the platform; we'll filter by success)
            let candidateKeys = [
                "user.alpha",
                "user.beta|pipe",
                "user.gamma\nline",
                "com.example.custom",
            ]

            // Values include '|' and newline to ensure no ambiguity
            let kvs: [(String, Data)] = [
                ("user.alpha", Data("v1|pipe\nend".utf8)),
                ("user.beta|pipe", Data("v2".utf8)),
                ("user.gamma\nline", Data("multi\nline|value".utf8)),
                ("com.example.custom", Data([0x00, 0xFF, 0x7C])),  // includes '|'=0x7C
            ]

            // Filter to keys we can actually set on this system by trying on f1
            var accepted: [(String, Data)] = []
            for (k, v) in kvs where candidateKeys.contains(k) {
                if setXAttr(f1, name: k, value: v) {
                    accepted.append((k, v))
                }
            }

            // Apply the same set to f2 but in reverse order to validate order-independence
            for (k, v) in accepted.reversed() {
                _ = setXAttr(f2, name: k, value: v)
            }

            let k1 = try await computeDiffKey(targetMount: t1, inspectorOptions: InspectorOptions(enableXAttrsCapture: true))
            let k2 = try await computeDiffKey(targetMount: t2, inspectorOptions: InspectorOptions(enableXAttrsCapture: true))

            // If no attributes were accepted, this test cannot validate order-independence.
            // In that case, still assert that keys are equal because contents and metadata match.
            #expect(k1 == k2)
        }
    }

    // MARK: c) Modified-only differences isolate distinct record bytes and change root hash

    @Test func modifiedOnlySymlinkTargetChangesKey() async throws {
        try await TestUtils.withTempDirAsync { root in
            let t = root.appendingPathComponent("t", isDirectory: true)
            try TestUtils.mkdir(t)
            try TestUtils.writeString(t.appendingPathComponent("a.txt"), "x")

            // Create symlink -> a.txt
            let link = t.appendingPathComponent("link")
            try TestUtils.makeSymlink(at: link, to: "a.txt")
            let k1 = try await computeDiffKey(targetMount: t, inspectorOptions: InspectorOptions(enableXAttrsCapture: true))

            // Change only symlink target
            try? FileManager.default.removeItem(at: link)
            try TestUtils.makeSymlink(at: link, to: "a2.txt")
            let k2 = try await computeDiffKey(targetMount: t, inspectorOptions: InspectorOptions(enableXAttrsCapture: true))

            #expect(k1 != k2)
        }
    }

    @Test func modifiedOnlyXattrsChangeKey() async throws {
        try await TestUtils.withTempDirAsync { root in
            let t = root.appendingPathComponent("t", isDirectory: true)
            try TestUtils.mkdir(t)
            let f = t.appendingPathComponent("a.txt")
            try TestUtils.writeString(f, "data")

            let k1 = try await computeDiffKey(targetMount: t, inspectorOptions: InspectorOptions(enableXAttrsCapture: true))

            // Add only xattr (no content change)
            _ = setXAttr(f, name: "user.test.meta", value: Data("val|ue\n1".utf8))

            let k2 = try await computeDiffKey(targetMount: t, inspectorOptions: InspectorOptions(enableXAttrsCapture: true))
            #expect(k1 != k2)
        }
    }

    @Test func modifiedOnlyContentHashChangesKey() async throws {
        try await TestUtils.withTempDirAsync { root in
            let t = root.appendingPathComponent("t", isDirectory: true)
            try TestUtils.mkdir(t)
            let f = t.appendingPathComponent("a.txt")
            try TestUtils.writeString(f, "hello")

            let k1 = try await computeDiffKey(targetMount: t, inspectorOptions: InspectorOptions(enableXAttrsCapture: true))
            // Change only content
            try TestUtils.writeString(f, "HELLO")
            let k2 = try await computeDiffKey(targetMount: t, inspectorOptions: InspectorOptions(enableXAttrsCapture: true))

            #expect(k1 != k2)
        }
    }

    // MARK: d) Regression: Stable equality for identical trees with tricky names
    @Test func identicalTreesWithTrickyNamesHaveSameKey() async throws {
        try await TestUtils.withTempDirAsync { root in
            let t1 = root.appendingPathComponent("t1", isDirectory: true)
            let t2 = root.appendingPathComponent("t2", isDirectory: true)
            try TestUtils.mkdir(t1)
            try TestUtils.mkdir(t2)

            let names = [
                "foo|bar",
                " leading  space ",
                "line\nbreak",
                "πππ",
                String(repeating: "z", count: 250),
            ]

            for n in names {
                try TestUtils.writeString(t1.appendingPathComponent(n), "X")
                try TestUtils.writeString(t2.appendingPathComponent(n), "X")
            }

            let k1 = try await computeDiffKey(targetMount: t1, inspectorOptions: InspectorOptions(enableXAttrsCapture: true))
            let k2 = try await computeDiffKey(targetMount: t2, inspectorOptions: InspectorOptions(enableXAttrsCapture: true))
            #expect(k1 == k2)
        }
    }
}
