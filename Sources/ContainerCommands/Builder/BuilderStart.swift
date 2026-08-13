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
import ContainerBuild
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging
import SystemPackage
import TerminalProgress

extension Application {
    public struct BuilderStart: AsyncLoggableCommand {
        public static var configuration: CommandConfiguration {
            var config = CommandConfiguration()
            config.commandName = "start"
            config.abstract = "Start the builder container"
            return config
        }

        @Option(name: .shortAndLong, help: "Number of CPUs to allocate to the builder container")
        var cpus: Int64?

        @Option(
            name: .shortAndLong,
            help: "Amount of builder container memory (1MiByte granularity), with optional K, M, G, T, or P suffix"
        )
        var memory: String?

        @Option(
            name: .long,
            help: ArgumentHelp(
                """
                Flags for the buildkitd the builder launches, one string the way buildx's \
                --buildkitd-flags takes them. They begin with a dash, which is how an option \
                begins, so the value attaches to the option: --buildkitd-flags=--debug
                """,
                valueName: "flags"))
        var buildkitdFlags: String?

        @Option(
            name: .customLong("publish-buildkit-socket"),
            help: ArgumentHelp(
                "Publish the builder's buildkitd socket to this host path, where buildctl and buildx reach it directly",
                valueName: "path"))
        var publishBuildkitSocket: String?

        @OptionGroup
        public var dns: Flags.DNS

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await Application.loadContainerSystemConfig()
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
            try await BuilderStart.start(
                cpus: self.cpus,
                memory: self.memory,
                log: log,
                buildkitdFlags: self.buildkitdFlags,
                publishBuildkitSocket: self.publishBuildkitSocket,
                dnsNameservers: self.dns.nameservers,
                dnsDomain: self.dns.domain,
                dnsSearchDomains: self.dns.searchDomains,
                dnsOptions: self.dns.options,
                progressUpdate: progress.handler,
                containerSystemConfig: containerSystemConfig,
            )
            progress.finish()
        }

        static func start(
            cpus: Int64?,
            memory: String?,
            log: Logger,
            ssh: Bool = false,
            buildkitdFlags: String? = nil,
            publishBuildkitSocket: String? = nil,
            dnsNameservers: [String] = [],
            dnsDomain: String? = nil,
            dnsSearchDomains: [String] = [],
            dnsOptions: [String] = [],
            progressUpdate: @escaping ProgressUpdateHandler,
            containerSystemConfig: ContainerSystemConfig,
        ) async throws {
            await progressUpdate([
                .setDescription("Fetching BuildKit image"),
                .setItemsName("blobs"),
            ])
            let taskManager = ProgressTaskCoordinator()
            let fetchTask = await taskManager.startTask()

            let builderImage: String = containerSystemConfig.build.image
            let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
            let exportsMount: String = systemHealth.appRoot
                .appendingPathComponent(Application.BuilderCommand.builderResourceDir)
                .absolutePath()

            if !FileManager.default.fileExists(atPath: exportsMount) {
                try FileManager.default.createDirectory(
                    atPath: exportsMount,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }

            let builderPlatform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")

            // Every buildkit variable in the caller's environment rides into
            // the builder: BUILDKIT_HOST points the shim at a daemon of the
            // operator's choosing, the BUILDKIT_TLS set carries that
            // address's credentials, the color settings shape progress
            // output, and whatever buildkit documents next needs no new
            // plumbing here. NO_COLOR rides along as the conventional
            // outlier the color handling already honored.
            var targetEnvVars: [String] = []
            for (name, value) in ProcessInfo.processInfo.environment where name.hasPrefix("BUILDKIT_") {
                targetEnvVars.append("\(name)=\(value)")
            }
            if ProcessInfo.processInfo.environment["NO_COLOR"] != nil {
                targetEnvVars.append("NO_COLOR=true")
            }
            targetEnvVars.sort()

            let defaultBuildCPUs: Int = containerSystemConfig.build.cpus
            let defaultBuildMemory = containerSystemConfig.build.memory
            let resources = try Parser.resources(
                cpus: cpus,
                memory: memory,
                defaultCPUs: defaultBuildCPUs,
                defaultMemory: defaultBuildMemory,
            )

            let client = ContainerClient()
            let existingContainer = try? await client.get(id: "buildkit")
            if let existingContainer {
                let existingImage = existingContainer.configuration.image.reference
                let existingResources = existingContainer.configuration.resources
                let existingEnv = existingContainer.configuration.initProcess.environment
                let existingDNS = existingContainer.configuration.dns

                let existingManagedEnv = existingEnv.filter { envVar in
                    envVar.hasPrefix("BUILDKIT_") || envVar.hasPrefix("NO_COLOR=")
                }.sorted()

                let envChanged = existingManagedEnv != targetEnvVars

                let existingPublished = existingContainer.configuration.publishedSockets
                    .map { "\($0.containerPath):\($0.hostPath)" }.sorted()
                let targetPublished = (publishBuildkitSocket.map { ["/run/buildkit/buildkitd.sock:\($0)"] } ?? []).sorted()
                let publishChanged = existingPublished != targetPublished

                // Check if we need to recreate the builder due to different image
                let imageChanged = existingImage != builderImage
                let cpuChanged = existingResources.cpus != resources.cpus
                let memChanged = existingResources.memoryInBytes != resources.memoryInBytes
                let sshForwarded = existingContainer.configuration.ssh
                let sshWanted = ssh && ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil
                let sshChanged = sshForwarded != sshWanted
                let dnsChanged = {
                    if !dnsNameservers.isEmpty {
                        return existingDNS?.nameservers != dnsNameservers
                    }
                    if dnsDomain != nil {
                        return existingDNS?.domain != dnsDomain
                    }
                    if !dnsSearchDomains.isEmpty {
                        return existingDNS?.searchDomains != dnsSearchDomains
                    }
                    if !dnsOptions.isEmpty {
                        return existingDNS?.options != dnsOptions
                    }
                    return false
                }()

                switch existingContainer.status {
                case .running:
                    guard imageChanged || cpuChanged || memChanged || envChanged || dnsChanged || sshChanged || publishChanged else {
                        // If image, mem, cpu, env, DNS, and published sockets are the same, continue using the existing builder
                        return
                    }
                    // If they changed, stop and delete the existing builder
                    try await client.stop(id: existingContainer.id)
                    try await client.delete(id: existingContainer.id)
                case .stopped:
                    // If the builder is stopped and matches our requirements, start it
                    // Otherwise, delete it and create a new one
                    if imageChanged || cpuChanged || memChanged || envChanged || dnsChanged || sshChanged || publishChanged {
                        try? await client.delete(id: existingContainer.id)
                    } else {
                        do {
                            try await startBuildKit(client: client, id: existingContainer.id, progressUpdate, nil)
                            return
                        } catch {
                            log.warning(
                                "failed to restart existing stopped BuildKit container, recreating it",
                                metadata: [
                                    "id": "\(existingContainer.id)",
                                    "error": "\(error)",
                                ])
                        }
                        try? await client.delete(id: existingContainer.id)
                    }
                case .stopping:
                    throw ContainerizationError(
                        .invalidState,
                        message: "builder is stopping, please wait until it is fully stopped before proceeding"
                    )
                case .unknown:
                    break
                }
            }

            let useRosetta = containerSystemConfig.build.rosetta
            var shimArguments = [
                "--debug",
                "--vsock",
                useRosetta ? nil : "--enable-qemu",
            ].compactMap { $0 }
            if let buildkitdFlags {
                // One string of daemon flags, buildx's own contract for
                // --buildkitd-flags, handed to the shim after -- where it
                // passes them to buildkitd verbatim.
                shimArguments += ["--"] + buildkitdFlags.split(separator: " ").map(String.init)
            }

            guard ManagedContainer.nameValid(Builder.builderContainerId) else {
                throw ContainerizationError(.invalidArgument, message: "container ID \(Builder.builderContainerId) is not a valid container ID")
            }

            let image = try await ClientImage.fetch(
                reference: builderImage,
                platform: builderPlatform,
                containerSystemConfig: containerSystemConfig,
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

            let imageDesc = ImageDescription(
                reference: builderImage,
                descriptor: image.descriptor
            )

            let imageConfig = try await image.config(for: builderPlatform).config
            var environment = imageConfig?.env ?? []
            environment.append(contentsOf: targetEnvVars)

            let processConfig = ProcessConfiguration(
                executable: "/usr/local/bin/container-builder-shim",
                arguments: shimArguments,
                environment: environment,
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            )

            var config = ContainerConfiguration(id: Builder.builderContainerId, image: imageDesc, process: processConfig)
            config.resources = resources
            config.ssh = ssh && ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil
            if let publishBuildkitSocket {
                // buildkitd listens at its library default inside the VM;
                // publishing that socket puts a file on the host where
                // buildctl and buildx dial the daemon directly, the
                // daemon-socket convention Docker Desktop, colima, and
                // podman machine follow on macOS.
                config.publishedSockets = [
                    try PublishSocket(
                        containerPath: FilePath("/run/buildkit/buildkitd.sock"),
                        hostPath: FilePath(publishBuildkitSocket)
                    )
                ]
            }
            config.labels = [
                ResourceLabelKeys.plugin: "builder",
                ResourceLabelKeys.role: ResourceRoleValues.builder,
            ]
            config.capAdd = ["ALL"]
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
            // Enable Rosetta only if the user didn't ask to disable it
            config.rosetta = useRosetta

            let networkClient = NetworkClient()
            guard let defaultNetwork = try await networkClient.builtin else {
                throw ContainerizationError(.invalidState, message: "default network is not present")
            }
            config.networks = [
                AttachmentConfiguration(network: defaultNetwork.id, options: AttachmentOptions(hostname: Builder.builderContainerId))
            ]
            config.dns = ContainerConfiguration.DNSConfiguration(
                nameservers: dnsNameservers,
                domain: dnsDomain,
                searchDomains: dnsSearchDomains,
                options: dnsOptions
            )

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

            do {
                try await client.create(
                    configuration: config,
                    options: .default,
                    kernel: kernel
                )
            } catch let error as ContainerizationError where error.code == .exists {
                // A concurrent `container build` invocation already created the builder
                // while we were fetching the image/kernel above. `bootstrap` below is
                // idempotent, so just proceed against the container the winner created.
            }

            try await startBuildKit(client: client, id: Builder.builderContainerId, progressUpdate, taskManager)
            log.debug("starting BuildKit and BuildKit-shim")
        }
    }
}

// MARK: - BuildKit Start Helper

/// Starts the BuildKit process within the container
/// This function handles bootstrapping the container and starting the BuildKit process
private func startBuildKit(
    client: ContainerClient,
    id: String,
    _ progress: @escaping ProgressUpdateHandler,
    _ taskManager: ProgressTaskCoordinator? = nil
) async throws {
    do {
        let io = try ProcessIO.create(
            tty: false,
            interactive: false,
            detach: true
        )
        defer { try? io.close() }

        var dynamicEnv: [String: String] = [:]
        if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            dynamicEnv["SSH_AUTH_SOCK"] = sshAuthSock
        }

        let process = try await client.bootstrap(id: id, stdio: io.stdio, dynamicEnv: dynamicEnv)
        try await process.start()
        await taskManager?.finish()
        try io.closeAfterStart()
    } catch {
        try? await client.stop(id: id)
        try? await client.delete(id: id)
        if error is ContainerizationError {
            throw error
        }
        throw ContainerizationError(.internalError, message: "failed to start BuildKit: \(error)")
    }
}
