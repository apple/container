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
        #expect(decoded.exitCode == nil)
        #expect(decoded.exitedAt == nil)
    }

    @Test func roundTripsTheExit() throws {
        let exitedAt = Date(timeIntervalSinceReferenceDate: 812_571_436)
        let status = ContainerStatus(state: .stopped, networks: [], exitCode: 7, exitedAt: exitedAt)
        let decoded = try JSONDecoder().decode(ContainerStatus.self, from: JSONEncoder().encode(status))
        #expect(decoded.exitCode == 7)
        #expect(decoded.exitedAt == exitedAt)
    }

    @Test func decodesStatusWrittenBeforeTheExitFieldsExisted() throws {
        let json = Data(#"{"state":"stopped","networks":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(ContainerStatus.self, from: json)
        #expect(decoded.state == .stopped)
        #expect(decoded.exitCode == nil)
        #expect(decoded.exitedAt == nil)
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

    @Test func factoryCarriesTheExitFromTheSnapshot() {
        let exitedAt = Date(timeIntervalSinceReferenceDate: 812_571_436)
        let snapshot = ContainerSnapshot(
            configuration: makeTestConfiguration(id: "abc"), status: .stopped, networks: [],
            exitCode: 7, exitedAt: exitedAt
        )
        let mc = ManagedContainer(snapshot)
        #expect(mc.status.exitCode == 7)
        #expect(mc.status.exitedAt == exitedAt)
    }

    @Test func nameValidAcceptsContainerNames() {
        #expect(ManagedContainer.nameValid("my-container_1.2"))
        #expect(ManagedContainer.nameValid("ABC"))
        #expect(!ManagedContainer.nameValid("-bad"))
        #expect(!ManagedContainer.nameValid("a b"))
    }

    @Test func nameValidRejectsNamesLongerThan63Characters() {
        let maxValidName = String(repeating: "a", count: 63)
        let tooLongName = String(repeating: "a", count: 64)
        #expect(ManagedContainer.nameValid(maxValidName))
        #expect(!ManagedContainer.nameValid(tooLongName))
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
