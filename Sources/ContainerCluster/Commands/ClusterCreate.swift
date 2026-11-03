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
import ContainerClusterServiceClient
import ContainerLog
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Darwin
import Foundation
import Logging
import TerminalProgress

public struct ClusterCreate: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create and start a local Kubernetes cluster and optional worker nodes"
    )

    @Option(name: .long, help: "Cluster name")
    var name: String = ClusterHelper.defaultName

    @Flag(name: [.customLong("rm"), .long], help: "Remove the cluster container after it stops")
    var remove: Bool = false

    @OptionGroup(title: "Resource options")
    var resourceFlags: Flags.Resource

    @OptionGroup(title: "Registry options")
    var registryFlags: Flags.Registry

    @OptionGroup(title: "Image fetch options")
    var imageFetchFlags: Flags.ImageFetch

    @Option(help: "Node image reference")
    var nodeImage: String = ClusterHelper.nodeImage

    @Option(name: .long, help: "Optional path to a CNI manifest to apply, or \"NONE\" to skip installing a CNI.")
    var cni: String?

    @Option(name: .long, help: "Number of worker nodes to create")
    var workers: UInt = 0

    @Flag(help: "Let nodes pull images from the local image store")
    var sharedImageStore = false

    public func validate() throws {
        guard workers <= ClusterConfiguration.maxWorkers else {
            throw ValidationError("--workers must be at most \(ClusterConfiguration.maxWorkers)")
        }
    }

    public func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: ClusterHelper.pluginName)

        let skipCNI = cni?.uppercased() == ClusterHelper.noCNIName
        if let cni, !skipCNI {
            guard FileManager.default.fileExists(atPath: cni) else {
                throw ContainerizationError(.invalidArgument, message: "CNI manifest not found at \(cni)")
            }
        }

        let containerSystemConfig: ContainerSystemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
        let fqdn = ClusterHelper.fqdn(for: name, domain: containerSystemConfig.dns.domain)

        // Validates the name, node image and worker count; fails before provisioning the node VM.
        let configuration = try ClusterConfiguration.make(
            name: name,
            nodeImage: nodeImage,
            remove: remove,
            sharedImageStore: sharedImageStore,
            workers: workers,
            cni: cni,
            fqdn: fqdn
        )

        let isTTY = isatty(FileHandle.standardError.fileDescriptor) == 1
        // TotalTasks include:
        // start, kubeadm init, one per worker, wait, write kubeconfig.
        let progressConfig = try ProgressConfig(
            showSpinner: isTTY,
            showTasks: true,
            showItems: true,
            ignoreSmallSize: true,
            totalTasks: 4 + Int(workers),
            clearOnFinish: isTTY,
            outputMode: isTTY ? .ansi : .plain
        )

        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()

        let controlPlane = try LinuxNodeProvisioner(
            name: name,
            clusterName: name,
            roles: workers == 0 ? [StandardRoles.controlPlane, StandardRoles.worker] : [StandardRoles.controlPlane],
            nodeImage: nodeImage,
            cpus: resourceFlags.cpus,
            memory: resourceFlags.memory,
            registryScheme: registryFlags.scheme,
            maxConcurrentDownloads: imageFetchFlags.maxConcurrentDownloads,
            remove: remove,
            containerSystemConfig: containerSystemConfig,
            fqdn: fqdn,
            sharedImageStore: sharedImageStore
        )
        let workerNodes = try (0..<Int(workers)).map { index in
            try LinuxNodeProvisioner(
                name: ClusterHelper.workerName(cluster: name, index: index + 1),
                clusterName: name,
                roles: [StandardRoles.worker],
                nodeImage: nodeImage,
                cpus: resourceFlags.cpus,
                memory: resourceFlags.memory,
                registryScheme: registryFlags.scheme,
                maxConcurrentDownloads: imageFetchFlags.maxConcurrentDownloads,
                remove: remove,
                containerSystemConfig: containerSystemConfig,
                sharedImageStore: sharedImageStore
            )
        }

        let clusterBootstrapper = ClusterBootstrapper(
            name: name,
            kubernetesVersion: configuration.kubernetesVersion,
            cni: cni,
            fqdn: fqdn,
            sharedImageStore: sharedImageStore,
            controlPlane: controlPlane,
            workers: workerNodes
        )

        // Record the cluster before provisioning. Fails `.exists` for a live duplicate and replaces stale records.
        let clusterClient = ClusterClient()
        try await clusterClient.create(configuration)

        do {
            try await clusterBootstrapper.create(progress: { progress.set(description: $0) }, log: log)
        } catch {
            // `.exists` means a container with this name is already there; the record may belong to another live create.
            if (error as? ContainerizationError)?.code != .exists { try? await clusterClient.delete(name: name) }
            throw error
        }

        progress.finish()
        print(name)
    }
}
