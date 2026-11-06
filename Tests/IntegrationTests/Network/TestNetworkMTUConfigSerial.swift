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

/// Serial tests for `[network] mtu` — the configuration file is read by every CLI invocation.
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

    @Test func testConfigSetsDefaultAttachmentMTU() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 1400\n", in: f)
            let c = "\(f.testID)-c"
            try await f.doLongRun(name: c, autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            let output = try f.doExec(c, cmd: ["ip", "link", "show", "eth0"])
            #expect(output.contains("mtu 1400"), "expected mtu 1400 in ip link output: \(output)")
        }
    }

    @Test func testNetworkFlagBeatsConfig() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 1400\n", in: f)
            let c = "\(f.testID)-c"
            try await f.doLongRun(name: c, args: ["--network", "default,mtu=1500"], autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            let output = try f.doExec(c, cmd: ["ip", "link", "show", "eth0"])
            #expect(output.contains("mtu 1500"), "expected mtu 1500 in ip link output: \(output)")
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkMTUBeatsConfig() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 1400\n", in: f)
            let net = "\(f.testID)-net"
            let c = "\(f.testID)-c"
            try f.doNetworkCreate(net, args: ["--mtu", "1500"])
            f.addCleanup { f.doNetworkDeleteIfExists(net) }

            try await f.doLongRun(name: c, args: ["--network", net], autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            let output = try f.doExec(c, cmd: ["ip", "link", "show", "eth0"])
            #expect(output.contains("mtu 1500"), "expected mtu 1500 in ip link output: \(output)")
        }
    }

    @Test func testNetworkInspectShowsTheConfiguredMTU() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 1400\n", in: f)
            let network = try f.inspectNetwork("default")
            #expect(network.configuration.mtu == nil)
            #expect(network.effectiveMTU == 1400)
        }
    }

    @Test func testInvalidConfigIsRejected() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 100\n", in: f)
            let c = "\(f.testID)-c"
            let result = try f.run(["run", "--rm", "--name", c, WarmupImage.alpine320.rawValue, "true"])
            #expect(result.status != 0)
            #expect(result.error.contains("invalid mtu value '100'"))
        }
    }

    /// The CLI validates the configuration when it creates a container, but not when it starts one,
    /// so only the runtime helper sees a value that went bad after the container was created.
    @Test func testInvalidConfigIsReportedWhenTheHelperStarts() async throws {
        try await ContainerFixture.with { f in
            let c = "\(f.testID)-c"
            try f.doCreate(name: c)
            f.addCleanup { try? f.doRemoveIfExists(c, force: true) }
            try Self.useConfiguration("[network]\nmtu = 100\n", in: f)

            let result = try f.run(["start", c])
            #expect(result.status != 0)
            #expect(result.error.contains("invalid mtu value '100'"), "expected the mtu error, got: \(result.error)")
        }
    }

    /// A packet the size of a QUIC handshake datagram must cross the attachment whole, both ways.
    @Test func testConfiguredMTUCarriesLargerPacketsUnfragmented() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 1500\n", in: f)
            let c = "\(f.testID)-c"
            try await f.doLongRun(name: c, autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            let script = """
                set -e
                gateway=$(ip route show default | awk '/ via / {print $3; exit}')
                ping -c 1 -W 5 -s 1280 "$gateway" >/dev/null
                awk '/^Ip:/ { if (!seen) { for (i = 1; i <= NF; i++) name[i] = $i; seen = 1 } else { for (i = 1; i <= NF; i++) if (name[i] == "ReasmReqds" || name[i] == "FragCreates") print name[i], $i } }' /proc/net/snmp
                """
            let output = try f.doExec(c, cmd: ["sh", "-c", script])
            #expect(output.contains("ReasmReqds 0"), "the reply was fragmented: \(output)")
            #expect(output.contains("FragCreates 0"), "the request was fragmented: \(output)")
        }
    }

    @Test func testConfigSetsMachineMTU() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 1400\n", in: f)
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: "ghcr.io/linuxcontainers/alpine:3.20")
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")
            let output = try f.doMachineRun(name: name, root: true, command: ["ip", "link", "show", "eth0"])
            #expect(output.contains("mtu 1400"), "expected mtu 1400 in ip link output: \(output)")
        }
    }

    @Test func testConfigSetsClusterNodeMTU() async throws {
        try await ContainerFixture.with { f in
            try Self.useConfiguration("[network]\nmtu = 1500\n", in: f)
            let name = "cluster-\(f.testID)"
            f.addCleanup { _ = try? f.run(["cluster", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            try f.run(["cluster", "create", "--name", name, "--workers", "1"]).check()

            for node in [name, "\(name)-worker-1"] {
                let interface = try f.doExec(node, cmd: ["sh", "-c", "ip route show default | awk '{print $5}'"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let output = try f.doExec(node, cmd: ["ip", "link", "show", interface])
                #expect(output.contains("mtu 1500"), "expected mtu 1500 on \(node): \(output)")
            }
        }
    }
}
