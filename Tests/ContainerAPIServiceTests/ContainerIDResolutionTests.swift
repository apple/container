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

import Testing

@testable import ContainerAPIService

struct ContainerIDResolutionTests {
    private let ids = [
        "983d8fe8-09b1-47ab-b65b-a6ce9da824a5",
        "983d8fff-65aa-4521-9ae2-69ed20c9f813",
        "custom-name",
    ]

    @Test func exactIDWins() throws {
        let id = "custom-name"

        let resolved = try ContainersService.resolveContainerID(id, in: ids)

        #expect(resolved == id)
    }

    @Test func uniquePrefixResolvesToFullID() throws {
        let resolved = try ContainersService.resolveContainerID("983d8fe", in: ids)

        #expect(resolved == "983d8fe8-09b1-47ab-b65b-a6ce9da824a5")
    }

    @Test func ambiguousPrefixThrows() {
        #expect(throws: (any Error).self) {
            try ContainersService.resolveContainerID("983d8", in: ids)
        }
    }

    @Test func unknownPrefixThrows() {
        #expect(throws: (any Error).self) {
            try ContainersService.resolveContainerID("missing", in: ids)
        }
    }
}
