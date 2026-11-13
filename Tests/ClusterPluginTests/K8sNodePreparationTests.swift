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

@testable import ContainerCluster

struct K8sNodePreparationTests {
    @Test
    func fallsBackToLegacyIptablesWhenNftablesIsUnavailable() throws {
        let fixture = try ShellFixture(nftExitCode: 1)
        defer { fixture.remove() }

        let result = try fixture.run()

        #expect(result.status == 0)
        #expect(result.log.contains("update-alternatives --set iptables \(fixture.legacyPath.path)"))
        #expect(result.log.contains("update-alternatives --set ip6tables \(fixture.ip6LegacyPath.path)"))
        #expect(result.log.contains("iptables -t mangle -A OUTPUT"))
        #expect(result.log.contains("iptables -t mangle -A FORWARD"))
    }

    @Test
    func keepsNftablesWhenItIsAvailable() throws {
        let fixture = try ShellFixture(nftExitCode: 0)
        defer { fixture.remove() }

        let result = try fixture.run()

        #expect(result.status == 0)
        #expect(!result.log.contains("update-alternatives"))
        #expect(result.log.contains("iptables -t mangle -A OUTPUT"))
        #expect(result.log.contains("iptables -t mangle -A FORWARD"))
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func quotesPathsContainingShellCharacters(nftExitCode: Int32) throws {
        let fixture = try ShellFixture(nftExitCode: nftExitCode, specialPaths: true)
        defer { fixture.remove() }

        let result = try fixture.run()

        #expect(result.status == 0)
        #expect(result.log.contains("iptables -t mangle -A OUTPUT"))
        #expect(result.log.contains("iptables -t mangle -A FORWARD"))
        if nftExitCode != 0 {
            #expect(result.log.contains("update-alternatives --set iptables \(fixture.legacyPath.path)"))
            #expect(result.log.contains("update-alternatives --set ip6tables \(fixture.ip6LegacyPath.path)"))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("injected").path))
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func repeatedSetupDoesNotDuplicateRules(nftExitCode: Int32) throws {
        let fixture = try ShellFixture(nftExitCode: nftExitCode)
        defer { fixture.remove() }

        #expect(try fixture.run().status == 0)
        let result = try fixture.run()

        #expect(result.status == 0)
        for chain in ["OUTPUT", "FORWARD"] {
            let calls = result.log.split(separator: "\n")
            #expect(calls.filter { $0.contains("-C \(chain)") }.count == 2)
            #expect(calls.filter { $0.contains("-A \(chain)") }.count == 1)
        }
    }

    @Test
    func failedRuleInsertionStopsSetup() throws {
        let fixture = try ShellFixture(nftExitCode: 0, appendExitCode: 1)
        defer { fixture.remove() }

        let result = try fixture.run()

        #expect(result.status != 0)
        #expect(result.log.contains("iptables -t mangle -A OUTPUT"))
        #expect(!result.log.contains("FORWARD"))
    }

}

private struct ShellFixture {
    let root: URL
    let logPath: URL
    let nftPath: URL
    let legacyPath: URL
    let ip6LegacyPath: URL
    let updateAlternativesPath: URL
    let iptablesPath: URL

    init(nftExitCode: Int32, specialPaths: Bool = false, appendExitCode: Int32 = 0) throws {
        let suffix = specialPaths ? " shell ' \" ; $(touch injected) `touch injected`\n" : ""
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + suffix)
        logPath = root.appendingPathComponent("calls.log")
        nftPath = root.appendingPathComponent("iptables-nft")
        legacyPath = root.appendingPathComponent("iptables-legacy")
        ip6LegacyPath = root.appendingPathComponent("ip6tables-legacy")
        updateAlternativesPath = root.appendingPathComponent("update-alternatives")
        iptablesPath = root.appendingPathComponent("iptables")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(nftPath, body: "exit \(nftExitCode)")
        try writeExecutable(
            updateAlternativesPath,
            body: "printf 'update-alternatives %s\\n' \"$*\" >> \"$CALL_LOG\""
        )
        try writeExecutable(
            iptablesPath,
            body: """
                printf 'iptables %s\\n' "$*" >> "$CALL_LOG"
                if [ "$3" = "-C" ]; then
                    [ -f "$RULE_STATE/$4" ]
                elif [ "$3" = "-A" ]; then
                    if [ "\(appendExitCode)" -ne 0 ]; then exit \(appendExitCode); fi
                    : > "$RULE_STATE/$4"
                else
                    exit 2
                fi
                """
        )
    }

    func run() throws -> (status: Int32, log: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "set -e\n"
                + LinuxNodeProvisioner.iptablesSetupScript(
                    nftPath: nftPath.path,
                    legacyPath: legacyPath.path,
                    ip6LegacyPath: ip6LegacyPath.path,
                    updateAlternativesPath: updateAlternativesPath.path,
                    iptablesPath: iptablesPath.path
                ),
        ]
        process.currentDirectoryURL = root
        process.environment = ["CALL_LOG": logPath.path, "RULE_STATE": root.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        let log = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
        return (process.terminationStatus, log)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeExecutable(_ path: URL, body: String) throws {
        try "#!/bin/sh\n\(body)\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
}
