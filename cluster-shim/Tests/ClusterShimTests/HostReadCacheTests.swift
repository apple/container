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

import ContainerizationOCI
import Foundation
import Synchronization
import Testing

@testable import ClusterShim

/// A host store that counts size and read requests to another host store.
final class CountingHostStore: HostStore {
    let host: FakeHostStore
    let sizes = Mutex(0)
    let reads = Mutex(0)

    init(_ host: FakeHostStore) {
        self.host = host
    }

    func size(digest: String) async throws -> Int64 {
        sizes.withLock { $0 += 1 }
        return try await host.size(digest: digest)
    }

    func read(digest: String, offset: Int64, length: Int) async throws -> Data {
        reads.withLock { $0 += 1 }
        return try await host.read(digest: digest, offset: offset, length: length)
    }

    func readManifest(digest: String) async throws -> Data {
        try await host.readManifest(digest: digest)
    }

    func image(reference: String) async throws -> Descriptor {
        try await host.image(reference: reference)
    }
}

struct HostReadCacheTests {
    let data = Data("0123456789".utf8)

    func makeCache(windowSize: Int = 4, maxWindows: Int = 2) -> (HostReadCache, CountingHostStore) {
        let host = CountingHostStore(FakeHostStore(blobs: [digest(of: data): data]))
        return (HostReadCache(host: host, windowSize: windowSize, maxWindows: maxWindows), host)
    }

    @Test func readsWithinWindowAskHostOnce() async throws {
        let (cache, host) = makeCache()

        let first = try await cache.read(digest: digest(of: data), offset: 0, length: 2)
        let second = try await cache.read(digest: digest(of: data), offset: 2, length: 2)

        #expect(first == Data("01".utf8))
        #expect(second == Data("23".utf8))
        #expect(host.reads.withLock { $0 } == 1)
    }

    @Test func readStopsAtWindowEnd() async throws {
        let (cache, _) = makeCache()

        let read = try await cache.read(digest: digest(of: data), offset: 2, length: 6)

        #expect(read == Data("2345".utf8))
    }

    @Test func lastWindowIsClampedToBlobSize() async throws {
        let (cache, _) = makeCache()

        let read = try await cache.read(digest: digest(of: data), offset: 8, length: 4)

        #expect(read == Data("89".utf8))
    }

    @Test func oldestWindowIsEvicted() async throws {
        let (cache, host) = makeCache(maxWindows: 1)
        _ = try await cache.read(digest: digest(of: data), offset: 0, length: 1)
        _ = try await cache.read(digest: digest(of: data), offset: 4, length: 1)

        _ = try await cache.read(digest: digest(of: data), offset: 0, length: 1)

        #expect(host.reads.withLock { $0 } == 3)
    }

    @Test func sizeIsCached() async throws {
        let (cache, host) = makeCache()

        _ = try await cache.size(digest: digest(of: data))
        _ = try await cache.size(digest: digest(of: data))

        #expect(host.sizes.withLock { $0 } == 1)
    }
}
