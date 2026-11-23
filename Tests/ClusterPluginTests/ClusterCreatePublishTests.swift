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

import ContainerAPIClient
import ContainerResource
import Testing

@testable import ContainerCluster

@Suite("ClusterCreate --publish flag")
struct ClusterCreatePublishTests {
    @Test func defaultsToNoPorts() throws {
        #expect(try ClusterCreate.parse([]).publishPorts.isEmpty)
    }

    @Test func shortAndLongFormsAreCollectedInOrder() throws {
        let command = try ClusterCreate.parse(["-p", "80:80", "--publish", "127.0.0.1:8443:443/tcp"])
        #expect(command.publishPorts == ["80:80", "127.0.0.1:8443:443/tcp"])
    }

    @Test func invalidSpecIsRejected() {
        #expect(throws: (any Error).self) {
            try ClusterCreate.parse(["--publish", "not-a-port"])
        }
    }

    @Test func overlappingHostPortsAreRejected() {
        #expect(throws: (any Error).self) {
            try ClusterCreate.parse(["--publish", "8000-8010:30000-30010", "--publish", "8005:80"])
        }
    }

    @Test func sameHostPortOnDifferentProtocolsIsAccepted() throws {
        _ = try ClusterCreate.parse(["--publish", "53:53/tcp", "--publish", "53:53/udp"])
    }

    @Test func hostPortsExpandRanges() throws {
        let ports = try Parser.publishPorts(["80:80", "9000-9002:31000-31002"])
        #expect(ClusterHelper.hostPorts(ports) == [80, 9000, 9001, 9002])
    }
}
