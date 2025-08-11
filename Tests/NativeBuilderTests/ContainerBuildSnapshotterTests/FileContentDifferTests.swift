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

import Foundation
import Testing

@testable import ContainerBuildSnapshotter

@Suite struct FileContentDifferTests {

    @Test func attributesOnlyShortCircuit() throws {
        let d = FileContentDiffer()
        let r = try d.diff(oldURL: nil, newURL: nil, attributesOnly: true)
        #expect(r == .attributeOnly)
    }

    @Test func nilSidesMeanContentChanged() throws {
        let d = FileContentDiffer()
        // old only
        #expect(try d.diff(oldURL: URL(fileURLWithPath: "/tmp/missing"), newURL: nil) == .contentChanged)
        // new only
        #expect(try d.diff(oldURL: nil, newURL: URL(fileURLWithPath: "/tmp/missing")) == .contentChanged)
    }

    @Test func equalContentAttributeOnly() throws {
        try TestUtils.withTempDir { dir in
            let a = dir.appendingPathComponent("a.txt")
            let b = dir.appendingPathComponent("b.txt")
            try TestUtils.writeString(a, "same")
            try TestUtils.writeString(b, "same")

            let d = FileContentDiffer()
            let r = try d.diff(oldURL: a, newURL: b)
            #expect(r == .attributeOnly)
        }
    }

    @Test func changedContentDetected() throws {
        try TestUtils.withTempDir { dir in
            let a = dir.appendingPathComponent("a.txt")
            let b = dir.appendingPathComponent("b.txt")
            try TestUtils.writeString(a, "hello")
            try TestUtils.writeString(b, "world")

            let d = FileContentDiffer()
            let r = try d.diff(oldURL: a, newURL: b)
            #expect(r == .contentChanged)
        }
    }

    @Test func largeFileChunking() throws {
        try TestUtils.withTempDir { dir in
            let a = dir.appendingPathComponent("a.bin")
            let b = dir.appendingPathComponent("b.bin")
            // ~10MB payload
            let block = Data(repeating: 0xAB, count: 1024 * 1024)  // 1MiB
            var payload = Data()
            for _ in 0..<10 { payload.append(block) }
            try TestUtils.write(a, contents: payload)
            try TestUtils.write(b, contents: payload)

            let d = FileContentDiffer()
            #expect(try d.diff(oldURL: a, newURL: b) == .attributeOnly)

            // flip one byte
            var changed = payload
            changed[changed.count / 2] = 0xCD
            try TestUtils.write(b, contents: changed)

            #expect(try d.diff(oldURL: a, newURL: b) == .contentChanged)
        }
    }
}
