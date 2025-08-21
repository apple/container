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

/// Codec for canonical extended attributes encoding used across snapshotting and archiving.
enum XAttrCodec {
    /// Stable canonical encoding for xattrs used for digesting and sidecar emission.
    /// Format: repeated entries of [u32_be keyLen][key UTF-8][u32_be valLen][val bytes]
    static func encode(_ entries: [XAttrEntry]) -> Data {
        var out = Data()
        for e in entries {
            let keyData = e.key.data(using: .utf8) ?? Data()
            var klen = UInt32(keyData.count).bigEndian
            withUnsafeBytes(of: &klen) { rbp in
                out.append(rbp.bindMemory(to: UInt8.self))
            }
            out.append(keyData)
            var vlen = UInt32(e.value.count).bigEndian
            withUnsafeBytes(of: &vlen) { rbp in
                out.append(rbp.bindMemory(to: UInt8.self))
            }
            out.append(e.value)
        }
        return out
    }

    /// Decode from the canonical sidecar blob format.
    /// Best-effort: returns [] on malformed data instead of throwing.
    static func decode(_ data: Data) -> [XAttrEntry] {
        var idx = 0
        var out: [XAttrEntry] = []

        func readU32BE() -> Int? {
            guard idx + 4 <= data.count else { return nil }
            let val = data[idx..<(idx + 4)].reduce(0) { ($0 << 8) | Int($1) }
            idx += 4
            return val
        }

        while idx < data.count {
            guard let keyLen = readU32BE(), keyLen >= 0, idx + keyLen <= data.count else {
                return []
            }
            let keyData = data[idx..<(idx + keyLen)]
            idx += keyLen
            guard let valLen = readU32BE(), valLen >= 0, idx + valLen <= data.count else {
                return []
            }
            let valData = data[idx..<(idx + valLen)]
            idx += valLen

            let key = String(data: keyData, encoding: .utf8)?.lowercased() ?? ""
            out.append(XAttrEntry(key: key, value: Data(valData)))
        }
        return out
    }
}
