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

@testable import ContainerK8s

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
}

private struct ShellFixture {
    let root: URL
    let logPath: URL
    let nftPath: URL
    let legacyPath: URL
    let ip6LegacyPath: URL
    let updateAlternativesPath: URL
    let iptablesPath: URL

    init(nftExitCode: Int32) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
            body: "printf 'iptables %s\\n' \"$*\" >> \"$CALL_LOG\""
        )
    }

    func run() throws -> (status: Int32, log: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            K8sHelper.iptablesSetupScript(
                nftPath: nftPath.path,
                legacyPath: legacyPath.path,
                ip6LegacyPath: ip6LegacyPath.path,
                updateAlternativesPath: updateAlternativesPath.path,
                iptablesPath: iptablesPath.path
            ),
        ]
        process.environment = ["CALL_LOG": logPath.path]
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
