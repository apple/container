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

import ContainerTestSupport
import ContainerizationExtras
import Foundation
import Testing

@Suite
struct TestCLICreateCommand {
    @Test func testCreateArgsPassthrough() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let name = "\(f.testID)-c"
            try f.doCreate(name: name, image: image, args: ["echo", "-n", "hello", "world"])
            try f.doRemove(name)
        }
    }

    @Test func testCreateWithMACAddress() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let name = "\(f.testID)-c"
            let expectedMAC = try MACAddress("02:42:ac:11:00:03")

            try f.doCreate(name: name, image: image, networks: ["default,mac=\(expectedMAC)"])
            f.addCleanup { try? f.doStop(name) }
            try f.doStart(name)
            try await f.waitForContainerRunning(name)

            let inspect = try f.inspectContainer(name)
            #expect(inspect.networks.count > 0, "expected at least one network attachment")
            let actualMAC = inspect.networks[0].macAddress?.description ?? "nil"
            #expect(
                actualMAC == expectedMAC.description,
                "expected MAC address \(expectedMAC), got \(actualMAC)")
        }
    }

    @Test func testPublishPortParserMaxPorts() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let name = "\(f.testID)-c"
            var args: [String] = ["create", "--name", name]
            for i in 0..<64 {
                args += ["--publish", "127.0.0.1:\(8000 + i):\(9000 + i)"]
            }
            args += [image, "echo", "\"hello world\""]

            let result = try f.run(args)
            f.addCleanup { try? f.doRemove(name) }
            #expect(result.status == 0, "expected create with 64 ports to succeed, stderr: \(result.error)")
        }
    }

    @Test func testPublishPortParserTooManyPorts() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let name = "\(f.testID)-c"
            var args: [String] = ["create", "--name", name]
            for i in 0..<65 {
                args += ["--publish", "127.0.0.1:\(8000 + i):\(9000 + i)"]
            }
            args += [image, "echo", "\"hello world\""]

            let result = try f.run(args)
            f.addCleanup { try? f.doRemove(name) }
            #expect(result.status != 0, "expected create with 65 ports to fail")
        }
    }

    @Test func testCreateWithFQDNName() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            // Prefix with testID to avoid name collisions; hostname is the first FQDN component.
            let name = "\(f.testID).example.com"
            let expectedHostname = f.testID

            try f.doCreate(name: name, image: image)
            f.addCleanup { try? f.doStop(name) }
            try f.doStart(name)
            try await f.waitForContainerRunning(name)

            let inspect = try f.inspectContainer(name)
            let attachmentHostname = inspect.networks.first?.hostname ?? ""
            let gotHostname =
                attachmentHostname
                .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map { String($0) } ?? attachmentHostname
            #expect(
                gotHostname == expectedHostname,
                "expected hostname '\(expectedHostname)' from FQDN '\(name)', got '\(gotHostname)'")
        }
    }
}
