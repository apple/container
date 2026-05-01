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
import SystemPackage

/// Functions for managing local DNS domains for containers.
public struct HostDNSResolver {
    public static let defaultConfigPath = FilePath("/etc/resolver")

    // prefix used to mark our files as /etc/resolver/{prefix}{domainName}
    public static let containerizationPrefix = "containerization."
    public static let localhostOptionsRegex = #"options localhost:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})"#

    private let configPath: FilePath

    public init(configPath: FilePath = Self.defaultConfigPath) {
        self.configPath = configPath
    }

    /// Creates a DNS resolver configuration file for domain resolved by the application.
    public func createDomain(name: DNSName, localhost: IPAddress? = nil) throws {
        let name = name.pqdn

        let resolverFilename = "\(Self.containerizationPrefix)\(name)"
        guard let component = FilePath.Component(resolverFilename) else {
            throw ContainerizationError(.invalidState, message: "invalid resolver filename \(resolverFilename)")
        }
        let path = self.configPath.appending(component)
        let fm: FileManager = FileManager.default

        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: self.configPath.string, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ContainerizationError(.invalidState, message: "expected \(self.configPath.string) to be a directory, but found a file")
            }
        } else {
            try fm.createDirectory(atPath: self.configPath.string, withIntermediateDirectories: true)
        }

        guard !fm.fileExists(atPath: path.string) else {
            throw ContainerizationError(.exists, message: "domain \(name) already exists")
        }

        let dnsPort = localhost == nil ? "2053" : "1053"
        let options =
            localhost.map {
                HostDNSResolver.localhostOptionsRegex.replacingOccurrences(
                    of: #"\((.*?)\)"#, with: $0.description, options: .regularExpression)
            } ?? ""
        let resolverText = """
            domain \(name)
            search \(name)
            nameserver 127.0.0.1
            port \(dnsPort)
            \(options)
            """

        try resolverText.write(toFile: path.string, atomically: true, encoding: .utf8)
    }

    /// Removes a DNS resolver configuration file for domain resolved by the application.
    public func deleteDomain(name: DNSName) throws -> IPAddress? {
        let name = name.pqdn

        let resolverFilename = "\(Self.containerizationPrefix)\(name)"
        guard let component = FilePath.Component(resolverFilename) else {
            throw ContainerizationError(.invalidState, message: "invalid resolver filename \(resolverFilename)")
        }
        let path = self.configPath.appending(component)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.string) else {
            throw ContainerizationError(.notFound, message: "domain \(name) at \(path) not found")
        }

        var localhost: IPAddress?
        let content = try String(contentsOfFile: path.string, encoding: .utf8)
        if let match = content.firstMatch(of: try Regex(HostDNSResolver.localhostOptionsRegex)) {
            localhost = try? IPAddress(String(match[1].substring ?? ""))
        }

        do {
            try fm.removeItem(atPath: path.string)
        } catch {
            throw ContainerizationError(.invalidState, message: "cannot delete domain (try sudo?)")
        }

        return localhost
    }

    /// Lists application-created local DNS domains.
    public func listDomains() -> [DNSName] {
        let fm: FileManager = FileManager.default
        guard let filenames = try? fm.contentsOfDirectory(atPath: self.configPath.string) else {
            return []
        }

        return
            filenames
            .filter { $0.starts(with: Self.containerizationPrefix) }
            .compactMap { filename -> DNSName? in
                guard let component = FilePath.Component(filename) else { return nil }
                return try? getDomainFromResolver(path: self.configPath.appending(component))
            }
            .sorted { a, b in a.pqdn < b.pqdn }
    }

    /// Reinitializes the macOS DNS daemon.
    public static func reinitialize() throws {
        do {
            let kill = Foundation.Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            kill.arguments = ["-HUP", "mDNSResponder"]

            let null = FileHandle.nullDevice
            kill.standardOutput = null
            kill.standardError = null

            try kill.run()
            kill.waitUntilExit()
            let status = kill.terminationStatus
            guard status == 0 else {
                throw ContainerizationError(.internalError, message: "mDNSResponder restart failed with status \(status)")
            }
        }
    }

    private func getDomainFromResolver(path: FilePath) throws -> DNSName? {
        let text = try String(contentsOfFile: path.string, encoding: .utf8)
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let components = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard components.count == 2 else {
                continue
            }
            guard components[0] == "domain" else {
                continue
            }

            return try? DNSName(String(components[1]))
        }

        return nil
    }
}
