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
import Testing

@testable import ContainerResource

struct ContainerStatusTests {
    @Test func roundTrips() throws {
        let status = ContainerStatus(state: .running, networks: [], startedDate: nil)
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(ContainerStatus.self, from: data)
        #expect(decoded.state == .running)
        #expect(decoded.networks.isEmpty)
        #expect(decoded.startedDate == nil)
    }
}

struct ManagedContainerTests {
    @Test func encodesIdConfigurationStatusShape() throws {
        let mc = ManagedContainer(
            configuration: makeTestConfiguration(id: "abc", labels: ["k": "v"]),
            status: ContainerStatus(state: .running, networks: [], startedDate: nil)
        )
        let data = try JSONEncoder().encode(mc)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(obj.keys) == ["id", "configuration", "status"])
        #expect(obj["id"] as? String == "abc")
    }

    @Test func factoryMapsSnapshotFields() {
        let config = makeTestConfiguration(id: "abc")
        let snapshot = ContainerSnapshot(
            configuration: config, status: .running, networks: [], startedDate: nil
        )
        let mc = ManagedContainer(snapshot)
        #expect(mc.id == "abc")
        #expect(mc.name == "abc")
        #expect(mc.status.state == .running)
    }

    @Test func nameValidAcceptsContainerNames() {
        #expect(ManagedContainer.nameValid("my-container_1.2"))
        #expect(ManagedContainer.nameValid("ABC"))
        #expect(!ManagedContainer.nameValid("-bad"))
        #expect(!ManagedContainer.nameValid("a b"))
    }

    @Test func generateIdIsLowercasedUUID() {
        let id = ManagedContainer.generateId()
        #expect(id == id.lowercased())
        #expect(id.contains("-"))
        #expect(UUID(uuidString: id) != nil)
    }

    @Test func labelsDeriveFromConfiguration() {
        let mc = ManagedContainer(
            configuration: makeTestConfiguration(labels: ["com.example.role": "x"]),
            status: ContainerStatus(state: .stopped, networks: [], startedDate: nil)
        )
        #expect(mc.labels["com.example.role"] == "x")
    }
}
