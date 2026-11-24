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

import ContainerClusterServiceClient
import ContainerResource
import ContainerXPC
import ContainerizationError
import Foundation
import Testing

@testable import ContainerClusterService

// `XPCMessage.reply()` force-unwraps `xpc_dictionary_create_reply`, which returns NULL for messages
// that were not received over a connection, so the handlers are not exercised end to end here.
// Their pure decode/encode steps are tested instead.
@Suite("ClusterServiceHarness")
struct ClusterServiceHarnessTests {
    private func expectInvalid(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected error")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidArgument)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func decodeConfigurationRoundTrips() throws {
        let config = makeConfig("dev", workers: 1)
        let message = XPCMessage(route: .clusterCreate)
        message.set(key: .configuration, value: try JSONEncoder().encode(config))
        #expect(try ClusterServiceHarness.decodeConfiguration(message) == config)
    }

    @Test func decodeConfigurationMissingKey() {
        expectInvalid { _ = try ClusterServiceHarness.decodeConfiguration(XPCMessage(route: .clusterCreate)) }
    }

    @Test func decodeConfigurationMalformedJSON() {
        let message = XPCMessage(route: .clusterCreate)
        message.set(key: .configuration, value: Data("{not json".utf8))
        expectInvalid { _ = try ClusterServiceHarness.decodeConfiguration(message) }
    }

    @Test func decodeName() throws {
        let message = XPCMessage(route: .clusterGet)
        message.set(key: .name, value: "dev")
        #expect(try ClusterServiceHarness.decodeName(message) == "dev")
    }

    @Test func decodeNameMissingKey() {
        expectInvalid { _ = try ClusterServiceHarness.decodeName(XPCMessage(route: .clusterDelete)) }
    }

    @Test func encodeInfoRoundTrips() throws {
        let info = try ClusterService.resources(configurations: [makeConfig("dev")], snapshots: [makeControlPlane("dev")])[0]
        let data = try ClusterServiceHarness.encode(info)
        #expect(try JSONDecoder().decode(ClusterResource.self, from: data) == info)
        let listData = try ClusterServiceHarness.encode([info])
        #expect(try JSONDecoder().decode([ClusterResource].self, from: listData) == [info])
    }
}
