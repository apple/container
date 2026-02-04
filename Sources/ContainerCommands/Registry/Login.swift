//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ArgumentParser
import ContainerAPIClient
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerVersion
import Foundation

extension Application {
    public struct Login: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            abstract: "Log in to a registry"
        )

        @OptionGroup
        var registry: Flags.Registry

        @Flag(help: "Take the password from stdin")
        var passwordStdin: Bool = false

        @Option(name: .shortAndLong, help: "Registry user name")
        var username: String = ""

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Registry server name")
        var server: String

        public func run() async throws {
            var username = self.username
            var password = ""
            if passwordStdin {
                if username == "" {
                    throw ContainerizationError(
                        .invalidArgument, message: "must provide --username with --password-stdin")
                }
                guard let passwordData = try FileHandle.standardInput.readToEnd() else {
                    throw ContainerizationError(.invalidArgument, message: "failed to read password from stdin")
                }
                password = String(decoding: passwordData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let keychain = KeychainHelper(id: Constants.keychainID)
            if username == "" {
                username = try keychain.userPrompt(domain: server)
            }
            if password == "" {
                password = try keychain.passwordPrompt()
                print()
            }

            let server = Reference.resolveDomain(domain: server)
            let scheme = try RequestScheme(registry.scheme).schemeFor(host: server)
            let _url = "\(scheme)://\(server)"
            guard let url = URL(string: _url) else {
                throw ContainerizationError(.invalidArgument, message: "cannot convert \(_url) to URL")
            }
            guard let host = url.host else {
                throw ContainerizationError(.invalidArgument, message: "invalid host \(server)")
            }

            let client = RegistryClient(
                host: host,
                scheme: scheme.rawValue,
                port: url.port,
                authentication: BasicAuthentication(username: username, password: password),
                retryOptions: .init(
                    maxRetries: 10,
                    retryInterval: 300_000_000,
                    shouldRetry: ({ response in
                        response.status.code >= 500
                    })
                )
            )
            try await client.ping()
            try Self.saveCredentials(
                server: server,
                username: username,
                password: password,
                keychainId: Constants.keychainID
            )
            print("Login succeeded")
        }

        /// Save credentials to keychain with proper ACL to allow container-core-images plugin access.
        /// Uses the security CLI tool to set up ACL with -T flags for both container and plugin binaries.
        private static func saveCredentials(server: String, username: String, password: String, keychainId: String) throws {
            // Delete existing entry first (ignore errors if not found)
            let deleteProcess = Process()
            deleteProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            deleteProcess.arguments = [
                "delete-internet-password",
                "-s", server,
                "-d", keychainId
            ]
            deleteProcess.standardOutput = FileHandle.nullDevice
            deleteProcess.standardError = FileHandle.nullDevice
            try? deleteProcess.run()
            deleteProcess.waitUntilExit()

            // Get paths to binaries that need keychain access
            let containerPath = CommandLine.executablePathUrl.path
            let installRoot = CommandLine.executablePathUrl
                .deletingLastPathComponent()
                .appendingPathComponent("..")
                .standardized
            let pluginPath = installRoot
                .appendingPathComponent("libexec/container/plugins/container-core-images/bin/container-core-images")
                .standardized
                .path

            // Add new keychain entry with proper ACL using security CLI
            // The -T flags grant access to specified applications
            let addProcess = Process()
            addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            var args = [
                "add-internet-password",
                "-a", username,
                "-s", server,
                "-w", password,
                "-d", keychainId,
                "-T", containerPath,  // Grant access to container CLI
                "-U"  // Update if exists
            ]

            // Only add plugin path if the binary exists
            if FileManager.default.fileExists(atPath: pluginPath) {
                args.insert(contentsOf: ["-T", pluginPath], at: args.count - 1)
            }

            addProcess.arguments = args
            let errorPipe = Pipe()
            addProcess.standardOutput = FileHandle.nullDevice
            addProcess.standardError = errorPipe

            try addProcess.run()
            addProcess.waitUntilExit()

            if addProcess.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "unknown error"
                throw ContainerizationError(
                    .internalError,
                    message: "failed to save credentials to keychain: \(errorMessage)"
                )
            }
        }
    }
}
