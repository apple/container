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
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerVersion
import ContainerizationError
import Foundation
import Logging

extension Application {
    public struct SystemStatus: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show the status of `container` services and system-wide information"
        )

        @Option(name: .shortAndLong, help: "Launchd prefix for services")
        var prefix: String = "com.apple.container."

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let isRegistered = try ServiceManager.isRegistered(fullServiceLabel: "\(prefix)apiserver")
            if !isRegistered {
                try Output.render(payload: StatusPayload(status: "unregistered"), format: format) {
                    "apiserver is not running and not registered with launchd"
                }
                Application.exit(withError: ExitCode(1))
            }

            // Now ping our friendly daemon. Fail after 10 seconds with no response.
            do {
                let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
                let status = await Self.gather(health: health)
                try Output.render(payload: status, format: format) {
                    Self.statusTable(status)
                }
            } catch {
                try Output.render(payload: StatusPayload(status: "not running"), format: format) {
                    "apiserver is not running"
                }
                Application.exit(withError: ExitCode(1))
            }
        }

        /// Collects system-wide status from the CLI, the running daemon, and the
        /// loaded system configuration. Resource and defaults fields are populated
        /// best-effort and omitted when their source is unavailable.
        static func gather(health: SystemHealth) async -> StatusPayload {
            let client = ClientInfo(
                version: ReleaseVersion.version(),
                build: ReleaseVersion.buildType(),
                commit: ReleaseVersion.gitCommit() ?? "unspecified",
                appName: "container"
            )

            let host = HostInfo(
                architecture: Arch.hostArchitecture().rawValue,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                cpus: ProcessInfo.processInfo.processorCount
            )

            let server = ServerInfo(
                version: health.apiServerVersion,
                build: health.apiServerBuild,
                commit: health.apiServerCommit,
                appName: health.apiServerAppName
            )

            let paths = PathInfo(
                appRoot: health.appRoot.path(percentEncoded: false),
                installRoot: health.installRoot.path(percentEncoded: false),
                logRoot: health.logRoot?.string
            )

            var resources: ResourceCounts? = nil
            let containerClient = ContainerClient()
            if let all = try? await containerClient.list(filters: ContainerListFilters.all.withoutMachines()) {
                let running = all.filter { $0.status == .running }.count
                resources = ResourceCounts(
                    containersTotal: all.count,
                    containersRunning: running
                )
            }
            if let images = try? await ClientImage.list() {
                resources = Self.withImageCount(resources, imageCount: images.count)
            }

            var defaults: DefaultsInfo? = nil
            if let config = try? await Application.loadContainerSystemConfig() {
                defaults = DefaultsInfo(
                    registryDomain: config.registry.domain,
                    kernelBinaryPath: config.kernel.binaryPath,
                    containerCPUs: config.container.cpus,
                    containerMemory: config.container.memory.description,
                    builderImage: config.build.image,
                    initImage: config.vminit.image,
                    dnsDomain: config.dns.domain
                )
            }

            return StatusPayload(
                status: "running",
                client: client,
                server: server,
                host: host,
                paths: paths,
                resources: resources,
                defaults: defaults
            )
        }

        /// Records the image count on the resource counts when both are
        /// available. Returns the counts unchanged (including `nil`) when there
        /// are no resource counts yet, i.e. the daemon's container list was
        /// unavailable.
        static func withImageCount(_ resources: ResourceCounts?, imageCount: Int?) -> ResourceCounts? {
            guard var resources, let imageCount else { return resources }
            resources.images = imageCount
            return resources
        }

        static func statusTable(_ status: StatusPayload) -> String {
            var rows: [[String]] = [["FIELD", "VALUE"]]

            rows.append(["status", status.status])

            if let client = status.client {
                rows.append(["client.version", client.version])
                rows.append(["client.build", client.build])
                rows.append(["client.commit", client.commit])
            }

            if let host = status.host {
                rows.append(["host.os", host.operatingSystem])
                rows.append(["host.architecture", host.architecture])
                rows.append(["host.cpus", String(host.cpus)])
            }

            if let server = status.server {
                rows.append(["server.version", server.version])
                rows.append(["server.build", server.build])
                rows.append(["server.commit", server.commit])
                rows.append(["server.appName", server.appName])
            }

            if let paths = status.paths {
                rows.append(["paths.appRoot", paths.appRoot])
                rows.append(["paths.installRoot", paths.installRoot])
                rows.append(["paths.logRoot", paths.logRoot ?? ""])
            }

            if let resources = status.resources {
                rows.append(["containers.total", String(resources.containersTotal)])
                rows.append(["containers.running", String(resources.containersRunning)])
                if let images = resources.images {
                    rows.append(["images.total", String(images)])
                }
            }

            if let defaults = status.defaults {
                rows.append(["defaults.registryDomain", defaults.registryDomain])
                rows.append(["defaults.kernelBinaryPath", defaults.kernelBinaryPath])
                rows.append(["defaults.containerCPUs", String(defaults.containerCPUs)])
                rows.append(["defaults.containerMemory", defaults.containerMemory])
                rows.append(["defaults.builderImage", defaults.builderImage])
                rows.append(["defaults.initImage", defaults.initImage])
                if let dnsDomain = defaults.dnsDomain {
                    rows.append(["defaults.dnsDomain", dnsDomain])
                }
            }

            return TableOutput(rows: rows).format()
        }
    }

    struct StatusPayload: Codable {
        let status: String
        let client: ClientInfo?
        let server: ServerInfo?
        let host: HostInfo?
        let paths: PathInfo?
        let resources: ResourceCounts?
        let defaults: DefaultsInfo?

        init(
            status: String,
            client: ClientInfo? = nil,
            server: ServerInfo? = nil,
            host: HostInfo? = nil,
            paths: PathInfo? = nil,
            resources: ResourceCounts? = nil,
            defaults: DefaultsInfo? = nil
        ) {
            self.status = status
            self.client = client
            self.server = server
            self.host = host
            self.paths = paths
            self.resources = resources
            self.defaults = defaults
        }
    }

    struct ClientInfo: Codable {
        let version: String
        let build: String
        let commit: String
        let appName: String
    }

    struct ServerInfo: Codable {
        let version: String
        let build: String
        let commit: String
        let appName: String
    }

    struct HostInfo: Codable {
        let architecture: String
        let operatingSystem: String
        let cpus: Int
    }

    struct PathInfo: Codable {
        let appRoot: String
        let installRoot: String
        let logRoot: String?
    }

    struct ResourceCounts: Codable {
        let containersTotal: Int
        let containersRunning: Int
        var images: Int?
    }

    struct DefaultsInfo: Codable {
        let registryDomain: String
        let kernelBinaryPath: String
        let containerCPUs: Int
        let containerMemory: String
        let builderImage: String
        let initImage: String
        let dnsDomain: String?
    }
}
