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

struct TieredStoreTests {
    let hostData = Data("host blob".utf8)

    func makeStore(host: FakeHostStore) throws -> TieredStore {
        TieredStore(local: try LocalStore(root: try makeTemporaryDirectory()), host: host)
    }

    @Test func infoPrefersLocalBlob() async throws {
        let localData = Data("local".utf8)
        let store = try makeStore(host: FakeHostStore(blobs: [digest(of: localData): Data("different size".utf8)]))
        let writer = try await store.local.writer(ref: "ref", total: 0, expected: "")
        try writer.write(localData)
        try writer.commit(size: 0, expected: "")

        #expect(try await store.info(digest: digest(of: localData)).size == Int64(localData.count))
    }

    @Test func infoFallsBackToHost() async throws {
        let store = try makeStore(host: FakeHostStore(blobs: [digest(of: hostData): hostData]))

        #expect(try await store.info(digest: digest(of: hostData)).size == Int64(hostData.count))
    }

    @Test func infoMissingEverywhereIsNotFound() async throws {
        let store = try makeStore(host: FakeHostStore())

        do {
            _ = try await store.info(digest: digest(of: hostData))
            Issue.record("expected an error")
        } catch let error as RPCError {
            #expect(error.code == .notFound)
        }
    }

    @Test func readFallsBackToHost() async throws {
        let store = try makeStore(host: FakeHostStore(blobs: [digest(of: hostData): hostData]))

        let data = try await store.read(digest: digest(of: hostData), offset: 5, length: 4)

        #expect(data == Data("blob".utf8))
    }
}
