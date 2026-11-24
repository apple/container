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

@testable import ClusterHostStoreService

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

struct ConnectionLimitTests {
    @Test func acquireFailsPastMax() {
        let limit = ConnectionLimit(max: 2)
        #expect(limit.acquire())
        #expect(limit.acquire())
        #expect(!limit.acquire())
    }

    @Test func releaseFreesASlot() {
        let limit = ConnectionLimit(max: 1)
        #expect(limit.acquire())
        limit.release()
        #expect(limit.acquire())
    }
}
