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
import Foundation
import Testing

@Suite(.serialSuites)
class TestCLIRunCapabilities: CLITest {
    func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    // MARK: - Invalid capability names

    @Test func testCapDropInvalid() throws {
        let (_, _, error, status) = try run(arguments: [
            "run", "--rm", "--cap-drop=CHWOWZERS", alpine, "ls",
        ])
        #expect(status != 0, "expected non-zero exit for invalid cap-drop")
        #expect(error.contains("CHWOWZERS") || error.contains("invalid"), "expected error about invalid capability, got: \(error)")
    }

    @Test func testCapAddInvalid() throws {
        let (_, _, error, status) = try run(arguments: [
            "run", "--rm", "--cap-add=CHWOWZERS", alpine, "ls",
        ])
        #expect(status != 0, "expected non-zero exit for invalid cap-add")
        #expect(error.contains("CHWOWZERS") || error.contains("invalid"), "expected error about invalid capability, got: \(error)")
    }

    // MARK: - Config stored correctly via inspect

    @Test func testCapAddStored() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: ["--cap-add", "NET_ADMIN"])
            defer { try? doStop(name: name) }

            let inspectResp = try inspectContainer(name)
            #expect(inspectResp.configuration.capAdd.contains("CAP_NET_ADMIN"), "expected CAP_NET_ADMIN in capAdd")
            #expect(inspectResp.configuration.capDrop.isEmpty, "expected empty capDrop")

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapDropStored() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: ["--cap-drop", "MKNOD"])
            defer { try? doStop(name: name) }

            let inspectResp = try inspectContainer(name)
            #expect(inspectResp.configuration.capDrop.contains("CAP_MKNOD"), "expected CAP_MKNOD in capDrop")
            #expect(inspectResp.configuration.capAdd.isEmpty, "expected empty capAdd")

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapAddDropALLStored() throws {
        do {
            let name = getTestName()
            try doLongRun(
                name: name,
                args: [
                    "--cap-drop", "ALL",
                    "--cap-add", "SETGID",
                    "--cap-add", "NET_RAW",
                ])
            defer { try? doStop(name: name) }

            let inspectResp = try inspectContainer(name)
            #expect(inspectResp.configuration.capDrop.contains("ALL"), "expected ALL in capDrop")
            #expect(inspectResp.configuration.capAdd.contains("CAP_SETGID"), "expected CAP_SETGID in capAdd")
            #expect(inspectResp.configuration.capAdd.contains("CAP_NET_RAW"), "expected CAP_NET_RAW in capAdd")

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapAddALLStored() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: ["--cap-add", "ALL"])
            defer { try? doStop(name: name) }

            let inspectResp = try inspectContainer(name)
            #expect(inspectResp.configuration.capAdd.contains("ALL"), "expected ALL in capAdd")

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapDropLowerCase() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: ["--cap-drop", "mknod"])
            defer { try? doStop(name: name) }

            let inspectResp = try inspectContainer(name)
            #expect(inspectResp.configuration.capDrop.contains("CAP_MKNOD"), "expected normalized CAP_MKNOD in capDrop")

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    // MARK: - In-container capability verification

    @Test func testCapDropMknodCannotMknod() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: ["--cap-drop", "MKNOD"])
            defer { try? doStop(name: name) }

            let (_, output, _, status) = try run(arguments: [
                "exec", name, "sh", "-c", "mknod /tmp/sda b 8 0 && echo ok",
            ])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed != "ok", "mknod should fail with CAP_MKNOD dropped")
            #expect(status != 0, "expected non-zero exit when mknod fails")
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapDropMknodLowerCaseCannotMknod() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: ["--cap-drop", "mknod"])
            defer { try? doStop(name: name) }

            let (_, output, _, status) = try run(arguments: [
                "exec", name, "sh", "-c", "mknod /tmp/sda b 8 0 && echo ok",
            ])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed != "ok", "mknod should fail with CAP_MKNOD dropped (lowercase)")
            #expect(status != 0, "expected non-zero exit when mknod fails")
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapDropALLCannotMknod() throws {
        do {
            let name = getTestName()
            try doLongRun(
                name: name,
                args: [
                    "--cap-drop", "ALL",
                    "--cap-add", "SETGID",
                ])
            defer { try? doStop(name: name) }

            let (_, output, _, status) = try run(arguments: [
                "exec", name, "sh", "-c", "mknod /tmp/sda b 8 0 && echo ok",
            ])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed != "ok", "mknod should fail when ALL dropped and MKNOD not re-added")
            #expect(status != 0, "expected non-zero exit")
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapDropALLAddMknodCanMknod() throws {
        do {
            let name = getTestName()
            try doLongRun(
                name: name,
                args: [
                    "--cap-drop", "ALL",
                    "--cap-add", "MKNOD",
                    "--cap-add", "SETGID",
                ])
            defer { try? doStop(name: name) }

            let output = try doExec(
                name: name,
                cmd: [
                    "sh", "-c", "mknod /tmp/sda b 8 0 && echo ok",
                ])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed == "ok", "mknod should succeed when MKNOD is explicitly re-added")

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapAddALLCanDownInterface() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: ["--cap-add", "ALL"])
            defer { try? doStop(name: name) }

            let output = try doExec(
                name: name,
                cmd: [
                    "sh", "-c", "ip link set lo down && echo ok",
                ])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed == "ok", "ip link set should succeed with ALL caps")

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapAddALLDropNetAdminCannotDownInterface() throws {
        do {
            let name = getTestName()
            try doLongRun(
                name: name,
                args: [
                    "--cap-add", "ALL",
                    "--cap-drop", "NET_ADMIN",
                ])
            defer { try? doStop(name: name) }

            let (_, output, _, status) = try run(arguments: [
                "exec", name, "sh", "-c", "ip link set lo down && echo ok",
            ])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed != "ok", "ip link set should fail with NET_ADMIN dropped")
            #expect(status != 0, "expected non-zero exit when NET_ADMIN is dropped")
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapAddNetAdminCanDownInterface() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: ["--cap-add", "NET_ADMIN"])
            defer { try? doStop(name: name) }

            let output = try doExec(
                name: name,
                cmd: [
                    "sh", "-c", "ip link set lo down && echo ok",
                ])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed == "ok", "ip link set should succeed with NET_ADMIN added")

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    // MARK: - Default capability behavior

    @Test func testDefaultCapChown() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: [])
            defer { try? doStop(name: name) }

            // chown should succeed with default caps (CAP_CHOWN is in OCI defaults)
            // doExec throws on non-zero exit, so success here means CAP_CHOWN is present
            _ = try doExec(name: name, cmd: ["chown", "100", "/tmp"])

            try doStop(name: name)
        } catch {
            Issue.record("chown should succeed with default caps: \(error)")
        }
    }

    @Test func testNonRootUserCannotReadShadow() throws {
        // Regression test for https://github.com/apple/container/issues/1352
        // Verifies that exec as a non-root user enforces file permissions.
        do {
            let name = getTestName()
            try doLongRun(name: name, args: [])
            defer { try? doStop(name: name) }

            // Root should be able to read /etc/shadow
            _ = try doExec(name: name, cmd: ["cat", "/etc/shadow"])

            // Non-root user (nobody) should NOT be able to read /etc/shadow
            let (_, _, _, status) = try run(arguments: [
                "exec", "-u", "nobody", name, "cat", "/etc/shadow",
            ])
            #expect(status != 0, "non-root user should not be able to read /etc/shadow")
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapDropChown() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: ["--cap-drop", "chown"])
            defer { try? doStop(name: name) }

            let (_, _, _, status) = try run(arguments: [
                "exec", name, "chown", "100", "/tmp",
            ])
            #expect(status != 0, "chown should fail when CAP_CHOWN is dropped")
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testDefaultCapFowner() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: [])
            defer { try? doStop(name: name) }

            // chmod on a file owned by root should succeed with CAP_FOWNER
            _ = try doExec(name: name, cmd: ["chmod", "777", "/etc/passwd"])

            try doStop(name: name)
        } catch {
            Issue.record("chmod should succeed with default caps: \(error)")
        }
    }

    // MARK: - Capability bitmask verification via /proc

    @Test func testCapDropALLShowsZeroCaps() throws {
        do {
            let name = getTestName()
            try doLongRun(
                name: name,
                args: [
                    "--cap-drop", "ALL",
                    "--cap-add", "SETUID",
                    "--cap-add", "SETGID",
                ])
            defer { try? doStop(name: name) }

            let output = try doExec(name: name, cmd: ["cat", "/proc/self/status"])
            // Verify CapEff is non-zero (SETUID and SETGID are granted)
            let lines = output.components(separatedBy: "\n")
            let capEffLine = lines.first { $0.hasPrefix("CapEff:") }
            #expect(capEffLine != nil, "expected CapEff line in /proc/self/status")

            if let capEffLine {
                let value = capEffLine.replacingOccurrences(of: "CapEff:", with: "").trimmingCharacters(in: .whitespaces)
                // With only SETUID (7) and SETGID (6), the bitmask should be non-zero but small
                #expect(value != "0000000000000000", "expected non-zero CapEff with SETUID+SETGID")

                // Verify it's NOT the full capability set
                #expect(value != "000001ffffffffff", "expected restricted caps, not full set")
            }

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testNoCapFlagsUsesDefaultCaps() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: [])
            defer { try? doStop(name: name) }

            let output = try doExec(name: name, cmd: ["cat", "/proc/self/status"])
            let lines = output.components(separatedBy: "\n")
            let capEffLine = lines.first { $0.hasPrefix("CapEff:") }
            #expect(capEffLine != nil, "expected CapEff line in /proc/self/status")

            if let capEffLine {
                let value = capEffLine.replacingOccurrences(of: "CapEff:", with: "").trimmingCharacters(in: .whitespaces)
                // Default OCI caps should produce a non-zero, restricted bitmask
                #expect(value != "0000000000000000", "expected non-zero CapEff with default OCI caps")
            }

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapAddALLShowsFullCaps() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: ["--cap-add", "ALL"])
            defer { try? doStop(name: name) }

            let output = try doExec(name: name, cmd: ["cat", "/proc/self/status"])
            let lines = output.components(separatedBy: "\n")
            let capEffLine = lines.first { $0.hasPrefix("CapEff:") }
            #expect(capEffLine != nil, "expected CapEff line in /proc/self/status")

            if let capEffLine {
                let value = capEffLine.replacingOccurrences(of: "CapEff:", with: "").trimmingCharacters(in: .whitespaces)
                // With ALL capabilities the bitmask should have all bits set for known caps
                #expect(value != "0000000000000000", "expected non-zero CapEff with ALL caps")
            }

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    @Test func testCapDropALLOnlyShowsZeroEffective() throws {
        do {
            let name = getTestName()
            // Drop ALL with no adds - effective set should be empty
            try doLongRun(name: name, args: ["--cap-drop", "ALL"])
            defer { try? doStop(name: name) }

            let output = try doExec(name: name, cmd: ["cat", "/proc/self/status"])
            let lines = output.components(separatedBy: "\n")
            let capEffLine = lines.first { $0.hasPrefix("CapEff:") }
            #expect(capEffLine != nil, "expected CapEff line in /proc/self/status")

            if let capEffLine {
                let value = capEffLine.replacingOccurrences(of: "CapEff:", with: "").trimmingCharacters(in: .whitespaces)
                #expect(value == "0000000000000000", "expected zero CapEff when ALL caps dropped, got \(value)")
            }

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }

    // MARK: - Multiple cap-add and cap-drop combined

    @Test func testMultipleCapAddDrop() throws {
        do {
            let name = getTestName()
            try doLongRun(
                name: name,
                args: [
                    "--cap-add", "SYS_ADMIN",
                    "--cap-add", "NET_RAW",
                    "--cap-drop", "MKNOD",
                    "--cap-drop", "CHOWN",
                ])
            defer { try? doStop(name: name) }

            let inspectResp = try inspectContainer(name)
            #expect(inspectResp.configuration.capAdd.count == 2)
            #expect(inspectResp.configuration.capDrop.count == 2)
            #expect(inspectResp.configuration.capAdd.contains("CAP_SYS_ADMIN"))
            #expect(inspectResp.configuration.capAdd.contains("CAP_NET_RAW"))
            #expect(inspectResp.configuration.capDrop.contains("CAP_MKNOD"))
            #expect(inspectResp.configuration.capDrop.contains("CAP_CHOWN"))

            // Verify MKNOD is actually dropped
            let (_, output, _, _) = try run(arguments: [
                "exec", name, "sh", "-c", "mknod /tmp/sda b 8 0 && echo ok",
            ])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed != "ok", "mknod should fail when CAP_MKNOD is dropped")

            try doStop(name: name)
        } catch {
            Issue.record("failed: \(error)")
        }
    }
}
