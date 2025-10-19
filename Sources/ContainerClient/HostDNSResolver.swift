//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
import Foundation

/// Functions for managing local DNS domains for containers.
public struct HostDNSResolver {
    public static let defaultConfigPath = URL(filePath: "/etc/resolver")

    // prefix used to mark our files as /etc/resolver/{prefix}{domainName}
    private static let containerizationPrefix = "containerization."

    private let configURL: URL

    public init(configURL: URL = Self.defaultConfigPath) {
        self.configURL = configURL
    }

    /// Creates a DNS resolver configuration file for domain resolved by the application.
    public func createDomain(name: String) throws {
        let path = self.configURL.appending(path: "\(Self.containerizationPrefix)\(name)").path
        let fm: FileManager = FileManager.default

        if fm.fileExists(atPath: self.configURL.path) {
            guard let isDir = try self.configURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir else {
                throw ContainerizationError(.invalidState, message: "expected \(self.configURL.path) to be a directory, but found a file")
            }
        } else {
            try fm.createDirectory(at: self.configURL, withIntermediateDirectories: true)
        }

        guard !fm.fileExists(atPath: path) else {
            throw ContainerizationError(.exists, message: "domain \(name) already exists")
        }

        let resolverText = """
            domain \(name)
            search \(name)
            nameserver 127.0.0.1
            port 2053
            """

        do {
            try resolverText.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw ContainerizationError(.invalidState, message: "failed to write resolver configuration for \(name)")
        }
    }

    /// Removes a DNS resolver configuration file for domain resolved by the application.
    public func deleteDomain(name: String) throws {
        let path = self.configURL.appending(path: "\(Self.containerizationPrefix)\(name)").path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw ContainerizationError(.notFound, message: "domain \(name) at \(path) not found")
        }

        do {
            try fm.removeItem(atPath: path)
        } catch {
            throw ContainerizationError(.invalidState, message: "cannot delete domain (try sudo?)")
        }
    }

    /// Lists application-created local DNS domains.
    public func listDomains() -> [String] {
        let fm: FileManager = FileManager.default
        guard
            let resolverPaths = try? fm.contentsOfDirectory(
                at: self.configURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        else {
            return []
        }

        return
            resolverPaths
            .filter { $0.lastPathComponent.starts(with: Self.containerizationPrefix) }
            .compactMap { try? getDomainFromResolver(url: $0) }
            .sorted()
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

    private func getDomainFromResolver(url: URL) throws -> String? {
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let components = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard components.count == 2 else {
                continue
            }
            guard components[0] == "domain" else {
                continue
            }

            return String(components[1])
        }

        return nil
    }
}
