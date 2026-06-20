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
import ContainerPersistence
import ContainerResource
import ContainerVersion
import Foundation

extension Application {
    public struct SystemInfo: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Display system-wide information"
        )

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let info = await Self.gather()
            try Output.render(payload: info, format: format) {
                Self.infoTable(info)
            }
        }

        /// Collects system information from the CLI, the daemon (if running), and
        /// the loaded system configuration. Daemon-dependent fields are populated
        /// only when the API server responds.
        static func gather() async -> InfoPayload {
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

            var server: ServerInfo? = nil
            var paths: PathInfo? = nil
            if let health = try? await ClientHealthCheck.ping(timeout: .seconds(2)) {
                server = ServerInfo(
                    version: health.apiServerVersion,
                    build: health.apiServerBuild,
                    commit: health.apiServerCommit,
                    appName: health.apiServerAppName
                )
                paths = PathInfo(
                    appRoot: health.appRoot.path(percentEncoded: false),
                    installRoot: health.installRoot.path(percentEncoded: false),
                    logRoot: health.logRoot?.string
                )
            }

            var resources: ResourceCounts? = nil
            if server != nil {
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

            return InfoPayload(
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

        static func infoTable(_ info: InfoPayload) -> String {
            var rows: [[String]] = [["FIELD", "VALUE"]]

            rows.append(["client.version", info.client.version])
            rows.append(["client.build", info.client.build])
            rows.append(["client.commit", info.client.commit])

            rows.append(["host.os", info.host.operatingSystem])
            rows.append(["host.architecture", info.host.architecture])
            rows.append(["host.cpus", String(info.host.cpus)])

            if let server = info.server {
                rows.append(["server.status", "running"])
                rows.append(["server.version", server.version])
                rows.append(["server.build", server.build])
                rows.append(["server.commit", server.commit])
            } else {
                rows.append(["server.status", "not running"])
            }

            if let paths = info.paths {
                rows.append(["paths.appRoot", paths.appRoot])
                rows.append(["paths.installRoot", paths.installRoot])
                rows.append(["paths.logRoot", paths.logRoot ?? ""])
            }

            if let resources = info.resources {
                rows.append(["containers.total", String(resources.containersTotal)])
                rows.append(["containers.running", String(resources.containersRunning)])
                if let images = resources.images {
                    rows.append(["images.total", String(images)])
                }
            }

            if let defaults = info.defaults {
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

    struct InfoPayload: Codable {
        let client: ClientInfo
        let server: ServerInfo?
        let host: HostInfo
        let paths: PathInfo?
        let resources: ResourceCounts?
        let defaults: DefaultsInfo?
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
