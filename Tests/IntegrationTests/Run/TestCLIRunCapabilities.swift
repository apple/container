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

@Suite
struct TestCLIRunCapabilities {
    private let alpine = WarmupImage.alpine320

    // MARK: - Invalid capability names

    @Test func testCapDropInvalid() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let result = try f.run(["run", "--rm", "--cap-drop=CHWOWZERS", image, "ls"])
            #expect(result.status != 0)
            #expect(result.error.contains("CHWOWZERS") || result.error.contains("invalid"))
        }
    }

    @Test func testCapAddInvalid() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let result = try f.run(["run", "--rm", "--cap-add=CHWOWZERS", image, "ls"])
            #expect(result.status != 0)
            #expect(result.error.contains("CHWOWZERS") || result.error.contains("invalid"))
        }
    }

    // MARK: - Config stored correctly via inspect

    @Test func testCapAddStored() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--cap-add", "NET_ADMIN"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.capAdd.contains("CAP_NET_ADMIN"))
            #expect(inspect.configuration.capDrop.isEmpty)
        }
    }

    @Test func testCapDropStored() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--cap-drop", "MKNOD"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.capDrop.contains("CAP_MKNOD"))
            #expect(inspect.configuration.capAdd.isEmpty)
        }
    }

    @Test func testCapAddDropALLStored() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c, image: image,
                args: ["--cap-drop", "ALL", "--cap-add", "SETGID", "--cap-add", "NET_RAW"],
                autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.capDrop.contains("ALL"))
            #expect(inspect.configuration.capAdd.contains("CAP_SETGID"))
            #expect(inspect.configuration.capAdd.contains("CAP_NET_RAW"))
        }
    }

    @Test func testCapAddALLStored() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--cap-add", "ALL"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.capAdd.contains("ALL"))
        }
    }

    @Test func testCapDropLowerCase() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--cap-drop", "mknod"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.capDrop.contains("CAP_MKNOD"))
        }
    }

    // MARK: - In-container capability verification

    @Test func testCapDropMknodCannotMknod() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--cap-drop", "MKNOD"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let result = try f.run(["exec", c, "sh", "-c", "mknod /tmp/sda b 8 0 && echo ok"])
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) != "ok")
            #expect(result.status != 0)
        }
    }

    @Test func testCapDropMknodLowerCaseCannotMknod() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--cap-drop", "mknod"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let result = try f.run(["exec", c, "sh", "-c", "mknod /tmp/sda b 8 0 && echo ok"])
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) != "ok")
            #expect(result.status != 0)
        }
    }

    @Test func testCapDropALLCannotMknod() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c, image: image,
                args: ["--cap-drop", "ALL", "--cap-add", "SETGID"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let result = try f.run(["exec", c, "sh", "-c", "mknod /tmp/sda b 8 0 && echo ok"])
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) != "ok")
            #expect(result.status != 0)
        }
    }

    @Test func testCapDropALLAddMknodCanMknod() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c, image: image,
                args: ["--cap-drop", "ALL", "--cap-add", "MKNOD", "--cap-add", "SETGID"],
                autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let output = try f.doExec(c, cmd: ["sh", "-c", "mknod /tmp/sda b 8 0 && echo ok"])
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
        }
    }

    @Test func testCapAddALLCanDownInterface() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--cap-add", "ALL"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let output = try f.doExec(c, cmd: ["sh", "-c", "ip link set lo down && echo ok"])
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
        }
    }

    @Test func testCapAddALLDropNetAdminCannotDownInterface() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c, image: image,
                args: ["--cap-add", "ALL", "--cap-drop", "NET_ADMIN"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let result = try f.run(["exec", c, "sh", "-c", "ip link set lo down && echo ok"])
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) != "ok")
            #expect(result.status != 0)
        }
    }

    @Test func testCapAddNetAdminCanDownInterface() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--cap-add", "NET_ADMIN"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let output = try f.doExec(c, cmd: ["sh", "-c", "ip link set lo down && echo ok"])
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
        }
    }

    // MARK: - Default capability behavior

    @Test func testDefaultCapChown() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            _ = try f.doExec(c, cmd: ["chown", "100", "/tmp"])
        }
    }

    @Test func testNonRootUserCannotReadShadow() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            _ = try f.doExec(c, cmd: ["cat", "/etc/shadow"])
            let result = try f.run(["exec", "-u", "nobody", c, "cat", "/etc/shadow"])
            #expect(result.status != 0, "non-root user should not be able to read /etc/shadow")
        }
    }

    @Test func testCapDropChown() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--cap-drop", "chown"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let result = try f.run(["exec", c, "chown", "100", "/tmp"])
            #expect(result.status != 0)
        }
    }

    @Test func testDefaultCapFowner() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            _ = try f.doExec(c, cmd: ["chmod", "777", "/etc/passwd"])
        }
    }

    // MARK: - Capability bitmask verification via /proc

    @Test func testCapDropALLShowsZeroCaps() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c, image: image,
                args: ["--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID"],
                autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let output = try f.doExec(c, cmd: ["cat", "/proc/self/status"])
            let capEff = output.components(separatedBy: "\n").first { $0.hasPrefix("CapEff:") }
            try #require(capEff != nil)
            let value = capEff!.replacingOccurrences(of: "CapEff:", with: "").trimmingCharacters(in: .whitespaces)
            #expect(value != "0000000000000000", "expected non-zero CapEff with SETUID+SETGID")
            #expect(value != "000001ffffffffff", "expected restricted caps, not full set")
        }
    }

    @Test func testNoCapFlagsUsesDefaultCaps() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let output = try f.doExec(c, cmd: ["cat", "/proc/self/status"])
            let capEff = output.components(separatedBy: "\n").first { $0.hasPrefix("CapEff:") }
            try #require(capEff != nil)
            let value = capEff!.replacingOccurrences(of: "CapEff:", with: "").trimmingCharacters(in: .whitespaces)
            #expect(value != "0000000000000000")
        }
    }

    @Test func testCapAddALLShowsFullCaps() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--cap-add", "ALL"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let output = try f.doExec(c, cmd: ["cat", "/proc/self/status"])
            let capEff = output.components(separatedBy: "\n").first { $0.hasPrefix("CapEff:") }
            try #require(capEff != nil)
            let value = capEff!.replacingOccurrences(of: "CapEff:", with: "").trimmingCharacters(in: .whitespaces)
            #expect(value != "0000000000000000")
        }
    }

    @Test func testCapDropALLOnlyShowsZeroEffective() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--cap-drop", "ALL"], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let output = try f.doExec(c, cmd: ["cat", "/proc/self/status"])
            let capEff = output.components(separatedBy: "\n").first { $0.hasPrefix("CapEff:") }
            try #require(capEff != nil)
            let value = capEff!.replacingOccurrences(of: "CapEff:", with: "").trimmingCharacters(in: .whitespaces)
            #expect(value == "0000000000000000", "expected zero CapEff when ALL caps dropped, got \(value)")
        }
    }

    @Test func testMultipleCapAddDrop() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c, image: image,
                args: [
                    "--cap-add", "SYS_ADMIN", "--cap-add", "NET_RAW",
                    "--cap-drop", "MKNOD", "--cap-drop", "CHOWN",
                ],
                autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.capAdd.count == 2)
            #expect(inspect.configuration.capDrop.count == 2)
            #expect(inspect.configuration.capAdd.contains("CAP_SYS_ADMIN"))
            #expect(inspect.configuration.capAdd.contains("CAP_NET_RAW"))
            #expect(inspect.configuration.capDrop.contains("CAP_MKNOD"))
            #expect(inspect.configuration.capDrop.contains("CAP_CHOWN"))

            let result = try f.run(["exec", c, "sh", "-c", "mknod /tmp/sda b 8 0 && echo ok"])
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) != "ok")
        }
    }
}
