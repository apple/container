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

import ContainerResource
import Containerization
import Foundation
import Testing

@testable import ContainerAPIClient

struct ContainerCreateResultTests {
    @Test func legacyAndResultCreateSignaturesRemainDistinct() {
        let client = ContainerClient()
        let legacyCreate: (ContainerConfiguration, ContainerCreateOptions, Kernel, String?, Data?) async throws -> Void = client.create
        let resultCreate: (ContainerConfiguration, ContainerCreateOptions, Kernel, String?, Data?) async throws -> ContainerCreateResult =
            client.createWithResult

        _ = legacyCreate
        _ = resultCreate
    }

    @Test func decodesAtomicCreateResult() throws {
        let expected = ContainerCreateResult(id: "created", instanceToken: "server-token")
        let data = try JSONEncoder().encode(expected)

        #expect(try ContainerClient.decodeCreateResult(data) == expected)
    }

    @Test func missingResultFromLegacyServerRemainsCompatible() throws {
        #expect(try ContainerClient.decodeCreateResult(nil) == nil)
    }

    @Test func ignoresFutureResultFields() throws {
        let data = Data(#"{"id":"created","instanceToken":"server-token","future":true}"#.utf8)
        let result = try #require(try ContainerClient.decodeCreateResult(data))

        #expect(result.id == "created")
        #expect(result.instanceToken == "server-token")
    }
}
