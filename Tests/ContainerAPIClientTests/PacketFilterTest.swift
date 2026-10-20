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

import ContainerizationError
import ContainerizationExtras
import DNSServer
import Foundation
import Synchronization
import SystemPackage
import Testing

@testable import ContainerAPIClient

struct PacketFilterTest {
    @Test
    func testRedirectRuleLifecycle() throws {
        try withTemporaryDirectory { tempPath in
            let configPath = tempPath.appending("pf.conf")
            let anchorPath = tempPath.appending("com.apple.container")
            try String(Self.config.dropLast()).write(toFile: configPath.string, atomically: true, encoding: .utf8)
            let commands = Mutex<[[String]]>([])
            let pf = PacketFilter(configPath: configPath, anchorsPath: tempPath) { arguments in
                commands.withLock { $0.append(arguments) }
                return 0
            }
            let from1 = try IPAddress("203.0.113.113")
            let from2 = try IPAddress("203.0.113.114")
            let to = try IPAddress("127.0.0.1")
            let domain1 = try DNSName("aaa.com")
            let domain2 = try DNSName("bbb.com")
            let rule1 = "rdr inet from any to \(from1) -> \(to) # \(domain1.pqdn)\n"
            let rule2 = "rdr inet from any to \(from2) -> \(to) # \(domain2.pqdn)\n"
            let configured = Self.config + "load anchor \"com.apple/container\" from \"\(anchorPath.string)\"\n"
            let reloadCommands = [
                ["-n", "-a", "com.apple/container", "-f", anchorPath.string],
                ["-a", "com.apple/container", "-f", anchorPath.string],
                ["-a", "com.apple.container", "-f", "/dev/null"],
            ]

            try pf.createRedirectRule(from: from1, to: to, domain: domain1)
            try pf.createRedirectRule(from: from1, to: to, domain: domain1)
            try pf.createRedirectRule(from: from2, to: to, domain: domain2)
            try pf.reinitialize()

            #expect(try String(contentsOfFile: anchorPath.string, encoding: .utf8) == rule1 + rule2)
            #expect(try String(contentsOfFile: configPath.string, encoding: .utf8) == configured)
            #expect(commands.withLock { $0 } == reloadCommands)

            try pf.removeRedirectRule(from: from1, to: to, domain: domain1)
            try pf.reinitialize()

            #expect(try String(contentsOfFile: anchorPath.string, encoding: .utf8) == rule2)
            #expect(try String(contentsOfFile: configPath.string, encoding: .utf8) == configured)
            #expect(commands.withLock { $0 } == reloadCommands + reloadCommands)

            try pf.removeRedirectRule(from: from2, to: to, domain: domain2)
            try pf.reinitialize()

            #expect(!FileManager.default.fileExists(atPath: anchorPath.string))
            #expect(try String(contentsOfFile: configPath.string, encoding: .utf8) == Self.config)
            #expect(commands.withLock { $0 } == reloadCommands + reloadCommands + Self.emptyReloadCommands)
        }
    }

    @Test(arguments: [false, true])
    func testLegacyRulesMigration(deleting: Bool) throws {
        try withTemporaryDirectory { tempPath in
            let configPath = tempPath.appending("pf.conf")
            let anchorPath = tempPath.appending("com.apple.container")
            try Self.legacyConfig(anchorPath: anchorPath).write(toFile: configPath.string, atomically: true, encoding: .utf8)
            let from = try IPAddress("203.0.113.113")
            let to = try IPAddress("127.0.0.1")
            let domain = try DNSName("aaa.com")
            let rule = "rdr inet from any to \(from) -> \(to) # \(domain.pqdn)\n"
            let retainedRule = "rdr inet from any to 203.0.113.114 -> 127.0.0.1 # bbb.com\n"
            let originalRules = deleting ? rule + retainedRule : retainedRule
            try originalRules.write(toFile: anchorPath.string, atomically: true, encoding: .utf8)
            let commands = Mutex<[[String]]>([])
            let pf = PacketFilter(configPath: configPath, anchorsPath: tempPath) { arguments in
                commands.withLock { $0.append(arguments) }
                return 0
            }

            if deleting {
                try pf.removeRedirectRule(from: from, to: to, domain: domain)
            } else {
                try pf.createRedirectRule(from: from, to: to, domain: domain)
            }
            try pf.reinitialize()

            let expectedRules = deleting ? retainedRule : retainedRule + rule
            let expectedConfig = Self.config + "load anchor \"com.apple/container\" from \"\(anchorPath.string)\"\n"
            #expect(try String(contentsOfFile: anchorPath.string, encoding: .utf8) == expectedRules)
            #expect(try String(contentsOfFile: configPath.string, encoding: .utf8) == expectedConfig)
            #expect(
                commands.withLock { $0 } == [
                    ["-n", "-a", "com.apple/container", "-f", anchorPath.string],
                    ["-a", "com.apple/container", "-f", anchorPath.string],
                    ["-a", "com.apple.container", "-f", "/dev/null"],
                ])
        }
    }

    @Test(arguments: [false, true])
    func testLegacyLastRuleDeletion(missingFile: Bool) throws {
        try withTemporaryDirectory { tempPath in
            let configPath = tempPath.appending("pf.conf")
            let anchorPath = tempPath.appending("com.apple.container")
            try Self.legacyConfig(anchorPath: anchorPath).write(toFile: configPath.string, atomically: true, encoding: .utf8)
            let from = try IPAddress("203.0.113.113")
            let to = try IPAddress("127.0.0.1")
            let domain = try DNSName("aaa.com")
            if !missingFile {
                let rule = "rdr inet from any to \(from) -> \(to) # \(domain.pqdn)\n"
                try rule.write(toFile: anchorPath.string, atomically: true, encoding: .utf8)
            }
            let commands = Mutex<[[String]]>([])
            let pf = PacketFilter(configPath: configPath, anchorsPath: tempPath) { arguments in
                commands.withLock { $0.append(arguments) }
                return 0
            }

            try pf.removeRedirectRule(from: from, to: to, domain: domain)
            try pf.reinitialize()

            #expect(!FileManager.default.fileExists(atPath: anchorPath.string))
            #expect(try String(contentsOfFile: configPath.string, encoding: .utf8) == Self.config)
            #expect(commands.withLock { $0 } == Self.emptyReloadCommands)
        }
    }

    @Test(arguments: [0, 1, 2])
    func testReinitializeStopsOnFailure(failingCommand: Int) throws {
        try withTemporaryDirectory { tempPath in
            let commands = Mutex<[[String]]>([])
            let pf = PacketFilter(configPath: tempPath.appending("pf.conf"), anchorsPath: tempPath) { arguments in
                commands.withLock { commands in
                    commands.append(arguments)
                    return commands.count - 1 == failingCommand ? 1 : 0
                }
            }

            #expect {
                try pf.reinitialize()
            } throws: { error in
                guard let error = error as? ContainerizationError else {
                    return false
                }
                return error.code == (failingCommand == 0 ? .internalError : .invalidState)
            }
            #expect(commands.withLock { $0 } == Array(Self.emptyReloadCommands.prefix(failingCommand + 1)))
        }
    }

    private static let config = """
        # Preserve com.apple.container configuration owned by other services.
        scrub-anchor "com.apple/*"
        nat-anchor "com.apple/*"
        rdr-anchor "com.apple/*"
        rdr-anchor "com.apple.container.other"
        dummynet-anchor "com.apple/*"
        anchor "com.apple/*"
        load anchor "com.apple" from "/etc/pf.anchors/com.apple"
        # load anchor "com.apple.container" from "/etc/pf.anchors/custom"

        """

    private static let emptyReloadCommands = [
        ["-n", "-a", "com.apple/container", "-f", "/dev/null"],
        ["-a", "com.apple/container", "-f", "/dev/null"],
        ["-a", "com.apple.container", "-f", "/dev/null"],
    ]

    private static func legacyConfig(anchorPath: FilePath) -> String {
        var config = Self.config
        for keyword in ["scrub-anchor", "nat-anchor", "rdr-anchor", "dummynet-anchor", "anchor"] {
            let wildcard = "\(keyword) \"com.apple/*\""
            config = config.replacingOccurrences(of: "\n\(wildcard)\n", with: "\n\(keyword) \"com.apple.container\"\n\(wildcard)\n")
        }
        return config + "load anchor \"com.apple.container\" from \"\(anchorPath.string)\"\n"
    }

    private func withTemporaryDirectory(_ body: (FilePath) throws -> Void) throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? fm.removeItem(at: tempURL) }
        try body(FilePath(tempURL.path))
    }
}
