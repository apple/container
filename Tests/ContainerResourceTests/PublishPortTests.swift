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

import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerResource

struct PublishPortTests {
    @Test
    func testPublishPortsNonOverlapping() throws {
        let ports = [
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 9000, containerPort: 8080, proto: .tcp, count: 100),
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 9100, containerPort: 8180, proto: .tcp, count: 100),
        ]
        #expect(!ports.hasOverlaps())
    }

    @Test
    func testPublishPortsOverlapping() throws {
        let ports = [
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 9000, containerPort: 8080, proto: .tcp, count: 101),
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 9100, containerPort: 8180, proto: .tcp, count: 100),
        ]
        #expect(ports.hasOverlaps())
    }

    @Test
    func testPublishPortsSamePortDifferentProtocols() throws {
        let ports = [
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 8080, containerPort: 8080, proto: .tcp, count: 1),
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 8080, containerPort: 8080, proto: .udp, count: 1),
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 1024, containerPort: 1024, proto: .tcp, count: 1025),
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 1024, containerPort: 1024, proto: .udp, count: 1025),
        ]
        #expect(!ports.hasOverlaps())
    }

    @Test
    func testPublishPortHostPortOverflowRejected() throws {
        #expect(throws: (any Error).self) {
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 65535, containerPort: 8080, proto: .tcp, count: 2)
        }
    }

    @Test
    func testPublishPortContainerPortOverflowRejected() throws {
        #expect(throws: (any Error).self) {
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 8080, containerPort: 65535, proto: .tcp, count: 2)
        }
    }

    @Test
    func testPublishPortZeroCountRejected() throws {
        #expect(throws: (any Error).self) {
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 8080, containerPort: 8080, proto: .tcp, count: 0)
        }
    }

    @Test
    func testPublishPortRangeEndingAtMaxValid() throws {
        // hostPort 65534 + count 2 → last port 65535, should be accepted
        _ = try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 65534, containerPort: 8080, proto: .tcp, count: 2)
    }

    @Test
    func testPublishPortSingleMaxPortValid() throws {
        _ = try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 65535, containerPort: 8080, proto: .tcp, count: 1)
    }

    @Test
    func testPublishPortDecodeRejectsHostPortOverflow() throws {
        let json = Data(#"{"hostAddress":"0.0.0.0","hostPort":65535,"containerPort":8080,"proto":"tcp","count":2}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PublishPort.self, from: json)
        }
    }

    @Test
    func testPublishPortDecodeRejectsContainerPortOverflow() throws {
        let json = Data(#"{"hostAddress":"0.0.0.0","hostPort":8080,"containerPort":65535,"proto":"tcp","count":2}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PublishPort.self, from: json)
        }
    }

    @Test
    func testHasOverlapsAtMaxPort() throws {
        let ports = [
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 65534, containerPort: 8080, proto: .tcp, count: 2),
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 65534, containerPort: 9090, proto: .tcp, count: 1),
        ]
        #expect(ports.hasOverlaps())
    }
}
