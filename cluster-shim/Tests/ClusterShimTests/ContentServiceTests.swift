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

import Foundation
import GRPCCore
import GRPCInProcessTransport
import SwiftProtobuf
import Testing

@testable import ClusterShim

struct ContentServiceTests {
    let hostData = Data("0123456789".utf8)

    /// Runs `body` with a content client for a service whose host store has `hostData`.
    func withContentClient<Result: Sendable>(
        _ body: (ContentAPI.Client<InProcessTransport.Client>, LocalStore) async throws -> Result
    ) async throws -> Result {
        let local = try LocalStore(root: try makeTemporaryDirectory())
        let host = FakeHostStore(blobs: [digest(of: hostData): hostData])
        let service = ContentService(store: TieredStore(local: local, host: host))
        return try await withInProcessServer(services: [service]) { client in
            try await body(ContentAPI.Client(wrapping: client), local)
        }
    }

    func writeRequest(_ action: Containerd_Services_Content_V1_WriteAction, ref: String = "ref") -> Containerd_Services_Content_V1_WriteContentRequest {
        var request = Containerd_Services_Content_V1_WriteContentRequest()
        request.action = action
        request.ref = ref
        return request
    }

    /// Sends `requests` on one Write call and returns the replies.
    func write(
        _ requests: [Containerd_Services_Content_V1_WriteContentRequest],
        client: ContentAPI.Client<InProcessTransport.Client>
    ) async throws -> [Containerd_Services_Content_V1_WriteContentResponse] {
        try await client.write { writer in
            try await writer.write(contentsOf: requests)
        } onResponse: { response in
            var replies: [Containerd_Services_Content_V1_WriteContentResponse] = []
            for try await reply in response.messages {
                replies.append(reply)
            }
            return replies
        }
    }

    @Test func infoFallsBackToHost() async throws {
        try await withContentClient { client, _ in
            var request = Containerd_Services_Content_V1_InfoRequest()
            request.digest = digest(of: hostData)

            let response = try await client.info(request)

            #expect(response.info.size == Int64(hostData.count))
        }
    }

    @Test func readReturnsRangeOfHostBlob() async throws {
        try await withContentClient { client, _ in
            var request = Containerd_Services_Content_V1_ReadContentRequest()
            request.digest = digest(of: hostData)
            request.offset = 6
            request.size = 3

            let data = try await client.read(request) { response in
                var data = Data()
                for try await message in response.messages {
                    data.append(message.data)
                }
                return data
            }

            #expect(data == Data("678".utf8))
        }
    }

    @Test func writeAndCommitStoresBlobLocally() async throws {
        let data = Data("written".utf8)
        try await withContentClient { client, local in
            var commit = writeRequest(.commit)
            commit.data = data
            commit.total = Int64(data.count)
            commit.expected = digest(of: data)

            let replies = try await write([writeRequest(.stat), commit], client: client)

            #expect(replies.map(\.action) == [.stat, .commit])
            #expect(replies.last?.digest == digest(of: data))
            #expect(try await local.info(digest: digest(of: data)).size == Int64(data.count))
        }
    }

    @Test func statReportsResumedOffset() async throws {
        try await withContentClient { client, _ in
            var partial = writeRequest(.write)
            partial.data = Data("abc".utf8)
            _ = try await write([partial], client: client)

            let replies = try await write([writeRequest(.stat)], client: client)

            #expect(replies.first?.offset == 3)
            #expect(replies.first?.digest == digest(of: Data("abc".utf8)))
        }
    }

    @Test func writeAtWrongOffsetIsOutOfRange() async throws {
        try await withContentClient { client, _ in
            var write = writeRequest(.write)
            write.offset = 5
            write.data = Data("x".utf8)

            do {
                _ = try await self.write([write], client: client)
                Issue.record("expected an error")
            } catch let error as RPCError {
                #expect(error.code == .outOfRange)
            }
        }
    }

    @Test func expectedDigestOnHostIsAlreadyExists() async throws {
        try await withContentClient { client, _ in
            var stat = writeRequest(.stat)
            stat.expected = digest(of: hostData)

            do {
                _ = try await write([stat], client: client)
                Issue.record("expected an error")
            } catch let error as RPCError {
                #expect(error.code == .alreadyExists)
            }
        }
    }

    @Test func listReturnsOnlyLocalBlobs() async throws {
        let data = Data("local".utf8)
        try await withContentClient { client, local in
            let writer = try await local.writer(ref: "ref", total: 0, expected: "")
            try writer.write(data)
            try writer.commit(size: 0, expected: "")

            let digests = try await client.list(Containerd_Services_Content_V1_ListContentRequest()) { response in
                var digests: [String] = []
                for try await message in response.messages {
                    digests += message.info.map(\.digest)
                }
                return digests
            }

            #expect(digests == [digest(of: data)])
        }
    }

    @Test func listStatusesReportsOpenIngest() async throws {
        try await withContentClient { client, _ in
            var partial = writeRequest(.write, ref: "partial")
            partial.data = Data("abc".utf8)
            _ = try await write([partial], client: client)

            let response = try await client.listStatuses(Containerd_Services_Content_V1_ListStatusesRequest())

            #expect(response.statuses.map(\.ref) == ["partial"])
        }
    }

    @Test func abortRemovesIngest() async throws {
        try await withContentClient { client, local in
            var partial = writeRequest(.write, ref: "partial")
            partial.data = Data("abc".utf8)
            _ = try await write([partial], client: client)
            var abort = Containerd_Services_Content_V1_AbortRequest()
            abort.ref = "partial"

            _ = try await client.abort(abort)

            #expect(try local.listStatuses().isEmpty)
        }
    }
}
