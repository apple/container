//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import ContainerBuild
import ContainerClient
import ContainerNetworkService
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import TerminalProgress

extension Application {
    struct BuilderStart: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            var config = CommandConfiguration()
            config.commandName = "start"
            config._superCommandName = "builder"
            config.abstract = "Start builder"
            config.usage = "\nbuilder start [command options]"
            config.helpNames = NameSpecification(arrayLiteral: .customShort("h"), .customLong("help"))
            return config
        }

        @Option(name: [.customLong("cpus"), .customShort("c")], help: "Number of CPUs to allocate to the container")
        public var cpus: Int64 = 2

        @Option(
            name: [.customLong("memory"), .customShort("m")],
            help:
                "Amount of memory in bytes, kilobytes (K), megabytes (M), or gigabytes (G) for the container, with MB granularity (for example, 1024K will result in 1MB being allocated for the container)"
        )
        public var memory: String = "2048MB"

        func run() async throws {
            let progressConfig = try ProgressConfig(
                showTasks: true,
                showItems: true,
                totalTasks: 4
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()
            try await Self.start(cpus: self.cpus, memory: self.memory, progressUpdate: progress.handler)
            progress.finish()
        }

        static func start(cpus: Int64?, memory: String?, progressUpdate: @escaping ProgressUpdateHandler) async throws {
            await progressUpdate([
                .setDescription("Fetching BuildKit image"),
                .setItemsName("blobs"),
            ])
            let taskManager = ProgressTaskCoordinator()
            let fetchTask = await taskManager.startTask()

            let builderImage: String = ClientDefaults.get(key: .defaultBuilderImage)
            let exportsMount: String = Application.appRoot.appendingPathComponent(".build").absolutePath()

            if !FileManager.default.fileExists(atPath: exportsMount) {
                try FileManager.default.createDirectory(
                    atPath: exportsMount,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }

            let builderPlatform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")

            let existingContainer = try? await ClientContainer.get(id: "buildkit")
            if let existingContainer {
                let existingImage = existingContainer.configuration.image.reference
                let existingResources = existingContainer.configuration.resources

                // Check if we need to recreate the builder due to different image
                let imageChanged = existingImage != builderImage
                let cpuChanged = {
                    if let cpus {
                        if existingResources.cpus != cpus {
                            return true
                        }
                    }
                    return false
                }()
                let memChanged = try {
                    if let memory {
                        let memoryInBytes = try Parser.resources(cpus: nil, memory: memory).memoryInBytes
                        if existingResources.memoryInBytes != memoryInBytes {
                            return true
                        }
                    }
                    return false
                }()

                switch existingContainer.status {
                case .running:
                    guard imageChanged || cpuChanged || memChanged else {
                        // If image, mem and cpu are the same, continue using the existing builder
                        return
                    }
                    // If they changed, stop and delete the existing builder
                    try await existingContainer.stop()
                    try await existingContainer.delete()
                case .stopped:
                    // If the builder is stopped and matches our requirements, start it
                    // Otherwise, delete it and create a new one
                    guard imageChanged || cpuChanged || memChanged else {
                        try await existingContainer.startBuildKit(progressUpdate, nil)
                        return
                    }
                    try await existingContainer.delete()
                case .stopping:
                    throw ContainerizationError(
                        .invalidState,
                        message: "builder is stopping, please wait until it is fully stopped before proceeding"
                    )
                case .unknown:
                    break
                }
            }

            let shimArguments: [String] = [
                "--debug",
                "--vsock",
            ]

            let id = "buildkit"
            try ContainerClient.Utility.validEntityName(id)

            let processConfig = ProcessConfiguration(
                executable: "/usr/local/bin/container-builder-shim",
                arguments: shimArguments,
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            )

            let resources = try Parser.resources(
                cpus: cpus,
                memory: memory
            )

            let image = try await ClientImage.fetch(
                reference: builderImage,
                platform: builderPlatform,
                progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progressUpdate)
            )
            // Unpack fetched image before use
            await progressUpdate([
                .setDescription("Unpacking BuildKit image"),
                .setItemsName("entries"),
            ])

            let unpackTask = await taskManager.startTask()
            _ = try await image.getCreateSnapshot(
                platform: builderPlatform,
                progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progressUpdate)
            )
            let imageConfig = ImageDescription(
                reference: builderImage,
                descriptor: image.descriptor
            )

            var config = ContainerConfiguration(id: id, image: imageConfig, process: processConfig)
            config.resources = resources
            config.mounts = [
                .init(
                    type: .tmpfs,
                    source: "",
                    destination: "/run",
                    options: []
                ),
                .init(
                    type: .virtiofs,
                    source: exportsMount,
                    destination: "/var/lib/container-builder-shim/exports",
                    options: []
                ),
            ]
            config.rosetta = true

            let network = try await ClientNetwork.get(id: ClientNetwork.defaultNetworkName)
            guard case .running(_, let networkStatus) = network else {
                throw ContainerizationError(.invalidState, message: "default network is not running")
            }
            config.networks = [network.id]
            let subnet = try CIDRAddress(networkStatus.address)
            let nameserver = IPv4Address(fromValue: subnet.lower.value + 1).description
            let nameservers = [nameserver]
            config.dns = ContainerConfiguration.DNSConfiguration(nameservers: nameservers)

            let kernel = try await {
                await progressUpdate([
                    .setDescription("Fetching kernel"),
                    .setItemsName("binary"),
                ])

                let kernel = try await ClientKernel.getDefaultKernel(for: .current)
                return kernel
            }()

            await progressUpdate([
                .setDescription("Starting BuildKit container")
            ])

            let container = try await ClientContainer.create(
                configuration: config,
                options: .default,
                kernel: kernel
            )

            try await container.startBuildKit(progressUpdate, taskManager)
        }
    }
}

// MARK: - ClientContainer Extension for BuildKit

extension ClientContainer {
    /// Starts the BuildKit process within the container
    /// This method handles bootstrapping the container and starting the BuildKit process
    fileprivate func startBuildKit(_ progress: @escaping ProgressUpdateHandler, _ taskManager: ProgressTaskCoordinator? = nil) async throws {
        do {
            let io = try ProcessIO.create(
                tty: false,
                interactive: false,
                detach: true
            )
            defer { try? io.close() }
            let process = try await bootstrap()
            _ = try await process.start(io.stdio)
            await taskManager?.finish()
            try io.closeAfterStart()
            log.debug("starting BuildKit and BuildKit-shim")
        } catch {
            try? await stop()
            try? await delete()
            if error is ContainerizationError {
                throw error
            }
            throw ContainerizationError(.internalError, message: "failed to start BuildKit: \(error)")
        }
    }
}
