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
import Testing

@testable import ClusterShim

struct LocalStoreTests {
    let data = Data("local blob".utf8)

    func makeStore() throws -> LocalStore {
        try LocalStore(root: try makeTemporaryDirectory())
    }

    func commit(_ data: Data, to store: LocalStore, ref: String = "ref") async throws {
        let writer = try await store.writer(ref: ref, total: Int64(data.count), expected: digest(of: data))
        try writer.write(data)
        try writer.commit(size: Int64(data.count), expected: digest(of: data))
    }

    @Test func committedBlobHasInfo() async throws {
        let store = try makeStore()
        try await commit(data, to: store)

        let info = try await store.info(digest: digest(of: data))

        #expect(info.digest == digest(of: data))
        #expect(info.size == Int64(data.count))
    }

    @Test func committedBlobReadsAtOffset() async throws {
        let store = try makeStore()
        try await commit(data, to: store)

        let read = try await store.read(digest: digest(of: data), offset: 6, length: 4)

        #expect(read == Data("blob".utf8))
    }

    @Test func commitRemovesIngest() async throws {
        let store = try makeStore()
        try await commit(data, to: store)

        #expect(try store.listStatuses().isEmpty)
    }

    @Test func missingBlobIsNotFound() async throws {
        let store = try makeStore()

        await #expect(throws: RPCError.self) {
            _ = try await store.info(digest: digest(of: data))
        }
    }

    @Test func malformedDigestIsInvalidArgument() async throws {
        let store = try makeStore()

        do {
            _ = try await store.info(digest: "sha256:nothex")
            Issue.record("expected an error")
        } catch let error as RPCError {
            #expect(error.code == .invalidArgument)
        }
    }

    @Test func secondWriterOnSameRefIsUnavailable() async throws {
        let store = try makeStore()
        let first = try await store.writer(ref: "ref", total: 0, expected: "")
        defer { first.close() }

        do {
            _ = try await store.writer(ref: "ref", total: 0, expected: "")
            Issue.record("expected an error")
        } catch let error as RPCError {
            #expect(error.code == .unavailable)
        }
    }

    @Test func writerForExistingBlobIsAlreadyExists() async throws {
        let store = try makeStore()
        try await commit(data, to: store)

        do {
            _ = try await store.writer(ref: "other", total: 0, expected: digest(of: data))
            Issue.record("expected an error")
        } catch let error as RPCError {
            #expect(error.code == .alreadyExists)
        }
    }

    @Test func closedWriterResumesAtOffset() async throws {
        let store = try makeStore()
        let first = try await store.writer(ref: "ref", total: Int64(data.count), expected: "")
        try first.write(data.prefix(5))
        first.close()

        let second = try await store.writer(ref: "ref", total: Int64(data.count), expected: "")
        defer { second.close() }

        #expect(second.offset == 5)
        #expect(second.digest == digest(of: data.prefix(5)))
    }

    @Test func resumedWriterCommitsWholeBlob() async throws {
        let store = try makeStore()
        let first = try await store.writer(ref: "ref", total: Int64(data.count), expected: "")
        try first.write(data.prefix(5))
        first.close()

        let second = try await store.writer(ref: "ref", total: Int64(data.count), expected: "")
        try second.write(data.dropFirst(5))
        try second.commit(size: Int64(data.count), expected: digest(of: data))

        #expect(try await store.info(digest: digest(of: data)).size == Int64(data.count))
    }

    @Test func truncateRestartsDigest() async throws {
        let store = try makeStore()
        let writer = try await store.writer(ref: "ref", total: 0, expected: "")
        defer { writer.close() }
        try writer.write(Data("junk".utf8))

        try writer.truncate()

        #expect(writer.offset == 0)
        #expect(writer.digest == digest(of: Data()))
    }

    @Test func commitWithWrongSizeIsFailedPrecondition() async throws {
        let store = try makeStore()
        let writer = try await store.writer(ref: "ref", total: 0, expected: "")
        try writer.write(data)

        do {
            try writer.commit(size: Int64(data.count) + 1, expected: "")
            Issue.record("expected an error")
        } catch let error as RPCError {
            #expect(error.code == .failedPrecondition)
        }
    }

    @Test func commitWithWrongDigestIsFailedPrecondition() async throws {
        let store = try makeStore()
        let writer = try await store.writer(ref: "ref", total: 0, expected: "")
        try writer.write(data)

        do {
            try writer.commit(size: 0, expected: digest(of: Data("other".utf8)))
            Issue.record("expected an error")
        } catch let error as RPCError {
            #expect(error.code == .failedPrecondition)
        }
    }

    @Test func commitReleasesLock() async throws {
        let store = try makeStore()
        try await commit(data, to: store)

        let writer = try await store.writer(ref: "ref", total: 0, expected: "")
        writer.close()
    }

    @Test func statusReportsIngest() async throws {
        let store = try makeStore()
        let writer = try await store.writer(ref: "ref", total: 10, expected: "")
        try writer.write(data.prefix(4))
        writer.close()

        let status = try store.status(ref: "ref")

        #expect(status.ref == "ref")
        #expect(status.offset == 4)
        #expect(status.total == 10)
    }

    @Test func abortRemovesIngest() async throws {
        let store = try makeStore()
        let writer = try await store.writer(ref: "ref", total: 0, expected: "")
        writer.close()

        try store.abort(ref: "ref")

        #expect(try store.listStatuses().isEmpty)
    }

    @Test func abortOfUnknownRefIsNotFound() throws {
        let store = try makeStore()

        do {
            try store.abort(ref: "ref")
            Issue.record("expected an error")
        } catch let error as RPCError {
            #expect(error.code == .notFound)
        }
    }

    @Test func walkListsCommittedBlobs() async throws {
        let store = try makeStore()
        try await commit(data, to: store)

        #expect(try store.walk().map(\.digest) == [digest(of: data)])
    }

    @Test func deleteRemovesBlob() async throws {
        let store = try makeStore()
        try await commit(data, to: store)

        try await store.delete(digest: digest(of: data))

        #expect(try store.walk().isEmpty)
    }

    @Test func deleteOfMissingBlobSucceeds() async throws {
        let store = try makeStore()

        try await store.delete(digest: digest(of: data))
    }
}
