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

import ContainerizationError
import CryptoKit
import Foundation
import Testing

@testable import ContainerBuild

// Tests for the write sessions the content-store stage keeps, one per blob the
// builder streams in, each holding the bytes and the running digest until the
// commit seals them.
@Suite class BuildRemoteContentWriteTests {
    private static func digest(of data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func testWriteAtZeroOffsetRestartsTheBlob() async throws {
        let sessions = BuildRemoteContentProxy.WriteSessions()
        let abandoned = Data(repeating: 0xaa, count: 32)
        let kept = Data("the bytes the commit seals".utf8)

        let held = try await sessions.append(ref: "layer", offset: 0, data: abandoned)
        #expect(held == UInt64(abandoned.count))

        let restarted = try await sessions.append(ref: "layer", offset: 0, data: kept)
        #expect(restarted == UInt64(kept.count))

        let result = try await sessions.close(ref: "layer")
        let closed = try #require(result)
        #expect(closed.written == UInt64(kept.count))
        #expect(closed.digest == Self.digest(of: kept))

        let onDisk = try Data(contentsOf: closed.url)
        #expect(onDisk == kept)

        try? FileManager.default.removeItem(at: closed.url)
    }

    @Test func testWriteAtAnOffsetTheSessionIsNotAtFails() async throws {
        let sessions = BuildRemoteContentProxy.WriteSessions()
        let held = try await sessions.append(ref: "layer", offset: 0, data: Data(repeating: 0xaa, count: 32))
        #expect(held == 32)

        await #expect(throws: ContainerizationError.self) {
            _ = try await sessions.append(ref: "layer", offset: 8, data: Data([0x01]))
        }

        let result = try await sessions.close(ref: "layer")
        let closed = try #require(result)
        try? FileManager.default.removeItem(at: closed.url)
    }

    @Test func testDiscardingLetsGoOfWhatWasNeverCommitted() async throws {
        let sessions = BuildRemoteContentProxy.WriteSessions()
        _ = try await sessions.append(ref: "layer", offset: 0, data: Data(repeating: 0xaa, count: 32))
        let dir = await sessions.dir
        #expect(FileManager.default.fileExists(atPath: dir.path))

        await sessions.discardAll()

        #expect(!FileManager.default.fileExists(atPath: dir.path))
        let afterDiscard = try await sessions.close(ref: "layer")
        #expect(afterDiscard == nil)
    }

    @Test func testABlobWrittenAfterDiscardingStartsAgain() async throws {
        let sessions = BuildRemoteContentProxy.WriteSessions()
        _ = try await sessions.append(ref: "layer", offset: 0, data: Data(repeating: 0xaa, count: 32))
        await sessions.discardAll()

        let kept = Data("written after the directory went away".utf8)
        let written = try await sessions.append(ref: "layer", offset: 0, data: kept)
        #expect(written == UInt64(kept.count))

        let result = try await sessions.close(ref: "layer")
        let closed = try #require(result)
        #expect(closed.digest == Self.digest(of: kept))

        await sessions.discardAll()
    }
}
