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

import ArgumentParser
import ContainerAPIClient
import ContainerPlugin
import ContainerVersion
import ContainerizationError
import Foundation

extension Application {
    public struct UpgradeCommand: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "upgrade",
            abstract: "Upgrade container to the latest or a specific release"
        )

        /// Launchd prefix of the services that must be stopped before upgrading.
        private static let launchdPrefix = "com.apple.container."

        @Option(name: [.customShort("v"), .customLong("release")], help: "Upgrade to a specific release version (defaults to the latest release)")
        var release: String?

        @Flag(name: .shortAndLong, help: "Force the upgrade even if the target version is already installed")
        var force = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let runningServices = try ServiceManager.enumerate()
                .filter { $0.hasPrefix(Self.launchdPrefix) }
            guard runningServices.isEmpty else {
                throw ContainerizationError(
                    .invalidState,
                    message: "`container` is still running. Please ensure the service is stopped by running `container system stop`"
                )
            }

            let targetRelease = try await fetchRelease()
            let target = targetRelease.tagName
            let installed = ReleaseVersion.version()

            guard UpgradePolicy.shouldUpgrade(target: target, installed: installed, force: force) else {
                if release == nil {
                    print("Container is already on latest version \(target) (use -f to force update)")
                } else {
                    print("Container is already on version \(target) (use -f to force update)")
                }
                return
            }
            if release == nil {
                print("Updating to latest version \(target)")
            } else {
                print("Updating to release version \(target)")
            }

            guard let package = targetRelease.installerPackage() else {
                throw ContainerizationError(.notFound, message: "No suitable package found")
            }
            if !package.isSigned {
                guard confirmUnsignedPackage() else {
                    print("Exiting without updating")
                    return
                }
                print("NOTE: re-run this command to upgrade to the signed package, when it becomes available")
            }

            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("container-upgrade-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            let packageFile = try await download(package: package, to: temporaryDirectory)
            try install(packageFile: packageFile)

            print("Updated successfully")
            try printInstalledVersion()
        }

        private func fetchRelease() async throws -> GitHubRelease {
            let endpoint = GitHubRelease.endpoint(forVersion: release)
            let failureMessage =
                release.map { "Release '\($0)' not found" } ?? "Failed fetching latest release"

            do {
                let (body, response) = try await URLSession.shared.data(from: endpoint)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw ContainerizationError(.notFound, message: failureMessage)
                }
                return try JSONDecoder().decode(GitHubRelease.self, from: body)
            } catch let error as ContainerizationError {
                throw error
            } catch {
                throw ContainerizationError(.internalError, message: "\(failureMessage): \(error)")
            }
        }

        private func confirmUnsignedPackage() -> Bool {
            print("No signed package found. Upgrade using the unsigned package instead? (Y/n): ", terminator: "")
            guard let answer = readLine() else {
                return false
            }
            return answer.range(of: "^[yY]([eE][sS])?$", options: .regularExpression) != nil
        }

        private func download(package: InstallerPackage, to directory: URL) async throws -> URL {
            print("Downloading package from: \(package.url.absoluteString)...")
            let (downloadedFile, response) = try await URLSession.shared.download(from: package.url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ContainerizationError(.internalError, message: "Failed to download package")
            }
            let packageFile = directory.appendingPathComponent(package.url.lastPathComponent)
            try FileManager.default.moveItem(at: downloadedFile, to: packageFile)

            let attributes = try FileManager.default.attributesOfItem(atPath: packageFile.path)
            let size = (attributes[.size] as? Int64) ?? 0
            guard size > 0 else {
                throw ContainerizationError(.empty, message: "Downloaded package is empty")
            }
            return packageFile
        }

        private func install(packageFile: URL) throws {
            print("Installing package to /usr/local...")
            let installer = Process()
            installer.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            installer.arguments = ["installer", "-pkg", packageFile.path, "-target", "/"]
            // Silence installer output like the script; stdin stays attached
            // so sudo can prompt for the password on the terminal.
            installer.standardOutput = FileHandle.nullDevice
            installer.standardError = FileHandle.nullDevice
            try installer.run()
            installer.waitUntilExit()
            guard installer.terminationStatus == 0 else {
                throw ContainerizationError(.internalError, message: "Installer failed")
            }
        }

        private func printInstalledVersion() throws {
            let verify = Process()
            verify.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            verify.arguments = ["container", "--version"]
            try verify.run()
            verify.waitUntilExit()
            guard verify.terminationStatus == 0 else {
                throw ContainerizationError(.notFound, message: "'container' command not found")
            }
        }
    }
}
