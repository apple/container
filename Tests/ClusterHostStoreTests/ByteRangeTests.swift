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
import NIOHTTP1
import Testing

@testable import cluster_hoststore

struct ByteRangeTests {
    @Test func openEndedRangeReadsToEnd() {
        #expect(HostStoreServer.byteRange("bytes=4-", size: 10) == 4..<10)
    }

    @Test func boundedRangeIncludesEnd() {
        #expect(HostStoreServer.byteRange("bytes=6-8", size: 10) == 6..<9)
    }

    @Test func endPastBlobIsClamped() {
        #expect(HostStoreServer.byteRange("bytes=6-100", size: 10) == 6..<10)
    }

    @Test func startAtSizeIsUnsatisfiable() {
        #expect(HostStoreServer.byteRange("bytes=10-", size: 10) == nil)
    }

    @Test func endBeforeStartIsRejected() {
        #expect(HostStoreServer.byteRange("bytes=8-6", size: 10) == nil)
    }

    @Test func otherUnitIsRejected() {
        #expect(HostStoreServer.byteRange("items=0-1", size: 10) == nil)
    }
}

struct LookupStatusTests {
    @Test func notFoundIs404() {
        #expect(HostStoreServer.status(for: ContainerizationError(.notFound, message: "missing")) == .notFound)
    }

    @Test func invalidArgumentIs400() {
        #expect(HostStoreServer.status(for: ContainerizationError(.invalidArgument, message: "bad digest")) == .badRequest)
    }

    @Test func otherErrorIs500() {
        #expect(HostStoreServer.status(for: CancellationError()) == .internalServerError)
    }
}
