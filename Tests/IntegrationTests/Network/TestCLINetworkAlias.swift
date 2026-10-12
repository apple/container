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

/// Tests for DNS aliases on network attachments. The aliases are resolved by querying the container
/// DNS server directly, so they do not depend on any resolver file under /etc/resolver.
@Suite
struct TestCLINetworkAlias {
    private static let dnsPort = 2053

    private struct DigResult {
        let status: String
        let answers: [String]
    }

    /// Asks the container DNS server for a record, and returns the response code and the answer data.
    private func dig(_ name: String, type: String = "A") throws -> DigResult {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/dig")
        process.arguments = [
            "@127.0.0.1", "-p", "\(Self.dnsPort)", "+time=2", "+tries=1", "+noall", "+answer", "+comments", name, type,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
        let status =
            lines.compactMap { line -> String? in
                guard let range = line.range(of: "status: ") else { return nil }
                return line[range.upperBound...].prefix { $0.isLetter }.description
            }.first ?? ""
        let answers = lines.compactMap { line -> String? in
            guard !line.isEmpty, !line.hasPrefix(";") else { return nil }
            return line.split(whereSeparator: \.isWhitespace).last.map(String.init)
        }
        return DigResult(status: status, answers: answers)
    }

    private func startContainer(_ f: ContainerFixture, name: String, aliases: [String]) async throws -> String {
        let spec = (["default"] + aliases.map { "alias=\($0)" }).joined(separator: ",")
        try await f.doLongRun(name: name, args: ["--network", spec], autoRemove: false, waitUntilRunning: true)
        f.addCleanup {
            try? f.doStop(name)
            try? f.doRemove(name)
        }
        let container = try f.inspectContainer(name)
        return "\(container.networks[0].ipv4Address.address)"
    }

    @Test func testAliasesResolveToTheContainer() async throws {
        try await ContainerFixture.with { f in
            let c = "\(f.testID)-c"
            let base = "\(f.testID).alias.test"
            let ip = try await startContainer(f, name: c, aliases: [base, ".\(base)"])

            try await f.retry(attempts: 10) {
                (try? self.dig(base).answers) == [ip]
            }

            // An exact alias resolves, and so does every name below a subtree alias.
            #expect(try dig(base).answers == [ip])
            #expect(try dig("web.\(base)").answers == [ip])
            #expect(try dig("a.b.\(base)").answers == [ip])

            // Names are case-insensitive.
            #expect(try dig("WEB.\(base.uppercased())").answers == [ip])

            // Matching is by label: a name that only ends with the base string does not match.
            #expect(try dig("evil\(base)").status == "NXDOMAIN")
            #expect(try dig("\(f.testID).other.test").status == "NXDOMAIN")

            // A name that exists but has no IPv6 address is NODATA, and not NXDOMAIN.
            #expect(try dig("web.\(base)", type: "AAAA").status == "NOERROR")
            #expect(try dig(base, type: "AAAA").status == "NOERROR")
        }
    }

    @Test func testAliasesStopResolvingWhenTheContainerStops() async throws {
        try await ContainerFixture.with { f in
            let c = "\(f.testID)-c"
            let base = "\(f.testID).alias.test"
            let ip = try await startContainer(f, name: c, aliases: [base, ".\(base)"])
            try await f.retry(attempts: 10) {
                (try? self.dig(base).answers) == [ip]
            }

            try f.doStop(c)

            try await f.retry(attempts: 15) {
                (try? self.dig(base).status) == "NXDOMAIN" && (try? self.dig("web.\(base)").status) == "NXDOMAIN"
            }
        }
    }

    @Test func testAliasConflictsAreRejected() async throws {
        try await ContainerFixture.with { f in
            let first = "\(f.testID)-first"
            let alias = "\(f.testID).alias.test"
            _ = try await startContainer(f, name: first, aliases: [alias])

            // Another container cannot declare the same alias.
            let second = "\(f.testID)-second"
            f.addCleanup { try? f.doRemove(second) }
            let sameAlias = try f.run(["run", "-d", "--name", second, "--network", "default,alias=\(alias)", WarmupImage.alpine320.rawValue, "sleep", "infinity"])
            #expect(sameAlias.status != 0)
            #expect(sameAlias.error.contains("already exist"))

            // And it cannot take the alias as its own name.
            let sameName = try f.run(["run", "-d", "--name", alias, WarmupImage.alpine320.rawValue, "sleep", "infinity"])
            f.addCleanup { try? f.doRemove(alias) }
            #expect(sameName.status != 0)
            #expect(sameName.error.contains("already exist"))
        }
    }

    @Test func testInvalidAliasesAreRejected() async throws {
        try await ContainerFixture.with { f in
            let c = "\(f.testID)-c"
            f.addCleanup { try? f.doRemove(c) }

            // An asterisk is not accepted, and the error points to the leading-dot form.
            let asterisk = try f.run(["run", "-d", "--name", c, "--network", "default,alias=*.\(f.testID).alias.test", WarmupImage.alpine320.rawValue, "sleep", "infinity"])
            #expect(asterisk.status != 0)
            #expect(asterisk.error.contains("leading dot"))

            // A subtree must be rooted at a name that the same attachment owns.
            let notOwned = try f.run(["run", "-d", "--name", c, "--network", "default,alias=.\(f.testID).unowned.test", WarmupImage.alpine320.rawValue, "sleep", "infinity"])
            #expect(notOwned.status != 0)
            #expect(notOwned.error.contains("must be below"))

            // A subtree base needs at least two labels, once the default domain is added.
            let tooShort = try f.run(["run", "-d", "--name", c, "--network", "default,alias=.test", WarmupImage.alpine320.rawValue, "sleep", "infinity"])
            #expect(tooShort.status != 0)
            // With a default domain configured the name is qualified first, and it is then not owned.
            #expect(tooShort.error.contains("at least 2 labels") || tooShort.error.contains("must be below"))
        }
    }
}
