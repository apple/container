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

@Suite struct XAttrCodecTests {

    @Test func roundTripEncodeDecode() {
        let entries: [XAttrEntry] = [
            XAttrEntry(key: "user:foo", value: Data([0x01, 0x02])),
            XAttrEntry(key: "security:selinux", value: Data("label".utf8)),
            XAttrEntry(key: "com.apple.quarantine", value: Data([0x10, 0x20, 0x30])),
        ]

        let blob = XAttrCodec.encode(entries)
        let decoded = XAttrCodec.decode(blob)

        #expect(decoded.count == entries.count)
        // keys are lowercased by decode; input keys already canonical/lower in these examples
        for (a, b) in zip(entries, decoded) {
            #expect(a.key.lowercased() == b.key)
            #expect(a.value == b.value)
        }
    }

    @Test func decodeMalformedReturnsEmpty() {
        // Truncated blob (length fields don't match)
        var bad = Data([0x00, 0x00, 0x00, 0x05])  // keyLen = 5, but no data follows
        bad.append(Data([0x01, 0x02]))  // still insufficient
        let out = XAttrCodec.decode(bad)
        #expect(out.isEmpty)
    }
}
