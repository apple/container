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
import Foundation
import Testing

/// Serial tests for `[network] mtu`, which sets the MTU of networks created without one.
///
/// These write to the isolated application root, so they only run when the test
/// targets set `CONTAINER_APP_ROOT`, and never touch the user's own configuration.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CONTAINER_APP_ROOT"]?.isEmpty == false))
struct TestNetworkMTUConfigSerial {
    /// Replaces the application root's configuration for one test and restores it afterwards.
    private static func useConfiguration(_ toml: String, in f: ContainerFixture) throws {
        let appRoot = try #require(ProcessInfo.processInfo.environment["CONTAINER_APP_ROOT"])
        let directory = URL(filePath: appRoot).appending(path: "config")
        let file = directory.appending(path: "config.toml")
        let original = try? Data(contentsOf: file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        try Data(toml.utf8).write(to: file)
        f.addCleanup {
            try? FileManager.default.removeItem(at: file)
            if let original { try? original.write(to: file) }
        }
    }

    /// Creates a network for one test and deletes it afterwards.
    private static func createNetwork(in f: ContainerFixture) throws -> String {
        let net = "\(f.testID)-net"
        try f.doNetworkCreate(net)
        f.addCleanup { f.doNetworkDeleteIfExists(net) }
        return net
    }

    /// Runs a container on a network and stops it afterwards.
    private static func runContainer(_ suffix: String, on network: String, in f: ContainerFixture) async throws -> String {
        let c = "\(f.testID)-\(suffix)"
        f.addCleanup {
            try? f.doStop(c)
            try? f.doRemove(c)
        }
        try await f.doLongRun(name: c, args: ["--network", network], autoRemove: false, waitUntilRunning: true)
        return c
    }

    @available(macOS 26, *)
    @Test func testConfigSetsMTUOfNewNetwork() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 1400\n", in: f)
            let net = try Self.createNetwork(in: f)
            #expect(try f.inspectNetwork(net).configuration.mtu == 1400)

            let c = try await Self.runContainer("c", on: net, in: f)
            let output = try f.doExec(c, cmd: ["ip", "link", "show", "eth0"])
            #expect(output.contains("mtu 1400"), "expected mtu 1400 in ip link output: \(output)")
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkKeepsItsMTUWhenConfigChanges() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 1400\n", in: f)
            let net = try Self.createNetwork(in: f)
            try Self.useConfiguration("[network]\nmtu = 1500\n", in: f)

            let c = try await Self.runContainer("c", on: net, in: f)
            let output = try f.doExec(c, cmd: ["ip", "link", "show", "eth0"])
            #expect(output.contains("mtu 1400"), "expected mtu 1400 in ip link output: \(output)")
        }
    }

    @available(macOS 26, *)
    @Test func testAttachmentMayLowerTheNetworkMTU() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 1500\n", in: f)
            let net = try Self.createNetwork(in: f)

            let c = try await Self.runContainer("c", on: "\(net),mtu=1400", in: f)
            let output = try f.doExec(c, cmd: ["ip", "link", "show", "eth0"])
            #expect(output.contains("mtu 1400"), "expected mtu 1400 in ip link output: \(output)")
        }
    }

    @available(macOS 26, *)
    @Test func testAttachmentMayNotRaiseTheNetworkMTU() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 1400\n", in: f)
            let net = try Self.createNetwork(in: f)

            let c = "\(f.testID)-c"
            let result = try f.run(["run", "--rm", "--name", c, "--network", "\(net),mtu=1500", WarmupImage.alpine320.rawValue, "true"])
            #expect(result.status != 0)
            #expect(result.error.contains("must not exceed the MTU 1400 of network \(net)"), "expected the mtu error, got: \(result.error)")
        }
    }

    @available(macOS 26, *)
    @Test func testInvalidConfigIsRejectedWhenCreatingANetwork() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 100\n", in: f)
            let net = "\(f.testID)-net"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }

            let result = try f.run(["network", "create", net])
            #expect(result.status != 0)
            #expect(result.error.contains("invalid mtu value '100'"), "expected the mtu error, got: \(result.error)")
        }
    }

    /// A packet the size of a QUIC handshake datagram must cross the attachment whole, both ways.
    @available(macOS 26, *)
    @Test func testNetworkMTUCarriesLargerPacketsUnfragmented() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 1500\n", in: f)
            let net = try Self.createNetwork(in: f)
            let c = try await Self.runContainer("c", on: net, in: f)

            let script = """
                set -e
                gateway=$(ip route show default | awk '/ via / {print $3; exit}')
                ping -c 1 -W 5 -s 1280 "$gateway" >/dev/null
                \(Self.fragmentCounters)
                """
            let output = try f.doExec(c, cmd: ["sh", "-c", script])
            #expect(output.contains("ReasmReqds 0"), "the reply was fragmented: \(output)")
            #expect(output.contains("FragCreates 0"), "the request was fragmented: \(output)")
        }
    }

    /// Frames larger than vmnet's own default of 1500 must cross between containers whole,
    /// which only works when the network's MTU is applied to vmnet as well as to the guests.
    @available(macOS 26, *)
    @Test func testNetworkMTUCarriesJumboFramesBetweenContainers() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 9000\n", in: f)
            let net = try Self.createNetwork(in: f)
            let sender = try await Self.runContainer("sender", on: net, in: f)
            let receiver = try await Self.runContainer("receiver", on: net, in: f)

            let address = try f.doExec(receiver, cmd: ["sh", "-c", "ip -4 -o addr show eth0 | awk '{split($4, a, \"/\"); print a[1]}'"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let script = """
                set -e
                ping -c 1 -W 5 -s 8000 "\(address)" >/dev/null
                \(Self.fragmentCounters)
                """
            let output = try f.doExec(sender, cmd: ["sh", "-c", script])
            #expect(output.contains("ReasmReqds 0"), "the reply was fragmented: \(output)")
            #expect(output.contains("FragCreates 0"), "the request was fragmented: \(output)")
        }
    }

    /// Prints the guest's IP reassembly and fragmentation counters.
    private static let fragmentCounters = """
        awk '/^Ip:/ { if (!seen) { for (i = 1; i <= NF; i++) name[i] = $i; seen = 1 } else { for (i = 1; i <= NF; i++) if (name[i] == "ReasmReqds" || name[i] == "FragCreates") print name[i], $i } }' /proc/net/snmp
        """
}
