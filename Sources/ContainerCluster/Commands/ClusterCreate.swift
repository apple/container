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
        abstract: "Create and start a local Kubernetes cluster and optional worker nodes",
        discussion: """
            --cpus and --memory size the control-plane node, or the single node if no workers are specified \
            (default 1/4 of host CPUs and memory, minimum 2 CPUs and 2g). \
            Size workers with --workers count=<n>,cpus=<n>,memory=<size>; a group's count defaults to 1, and cpus and memory left out default to the single-node sizes: 1/4 of host CPUs and memory (minimum 2 CPUs and 2g). \
            --virtualization and --kernel apply to the control-plane node, or the single node if no workers are specified. \
            Set them for workers with --workers virtualization=true,kernel=<path>.
            """
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

    @Flag(name: .long, help: "Expose virtualization capabilities to the control-plane node (requires host and guest support)")
    var virtualization = false

    @Option(
        name: .long,
        help: .init("Set a custom kernel path for the control-plane node", valueName: "path"),
        completion: .file(),
        transform: { WorkerGroup.absoluteKernelPath($0) })
    var kernel: String?

    @Option(
        name: .long,
        help: "Worker nodes to create: a number, or count=<n>,cpus=<n>,memory=<size>,virtualization=<bool>,kernel=<path> (repeat for groups of different workers)",
        transform: { try WorkerGroup(parsing: $0) })
    var workers: [WorkerGroup] = []

    @Flag(help: "Let nodes pull images from the local image store")
    var sharedImageStore = false

    public func validate() throws {
        // Fail before anything is created, the same as invalid --workers values do.
        do {
            if let cpus = resourceFlags.cpus { _ = try Parser.cpus(cpus) }
            if let memory = resourceFlags.memory { _ = try Parser.memoryInBytes(memory) }
        } catch {
            throw ValidationError(wrapping: error)
        }

        var total: UInt = 0
        for group in workers {
            // Compare against the remaining room so the running total can't overflow.
            guard group.count <= ClusterConfiguration.maxWorkers - total else {
                throw ValidationError("--workers must total at most \(ClusterConfiguration.maxWorkers) worker nodes")
            }
            total += group.count
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
        // Check every kernel before the first node is created, so a bad worker path doesn't fail after the control plane is up.
        for path in ([kernel] + workers.map(\.kernel)).compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: path) else {
                throw ContainerizationError(.notFound, message: "kernel file not found at path \(path)")
            }
        }

        let containerSystemConfig: ContainerSystemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
        let fqdn = ClusterHelper.fqdn(for: name, domain: containerSystemConfig.dns.domain)

        // validate() has already bounded the total by ClusterConfiguration.maxWorkers.
        let workerCount = workers.reduce(0) { $0 + Int($1.count) }

        // Validates the name, node image and worker count; fails before provisioning the node VM.
        let configuration = try ClusterConfiguration.make(
            name: name,
            nodeImage: nodeImage,
            remove: remove,
            sharedImageStore: sharedImageStore,
            workers: UInt(workerCount),
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
            totalTasks: 4 + workerCount,
            clearOnFinish: isTTY,
            outputMode: isTTY ? .ansi : .plain
        )

        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()

        let controlPlane = try LinuxNodeProvisioner(
            name: name,
            clusterName: name,
            roles: workerCount == 0 ? [StandardRoles.controlPlane, StandardRoles.worker] : [StandardRoles.controlPlane],
            nodeImage: nodeImage,
            cpus: resourceFlags.cpus,
            memory: resourceFlags.memory,
            virtualization: virtualization,
            kernel: kernel,
            registryScheme: registryFlags.scheme,
            maxConcurrentDownloads: imageFetchFlags.maxConcurrentDownloads,
            remove: remove,
            containerSystemConfig: containerSystemConfig,
            fqdn: fqdn,
            sharedImageStore: sharedImageStore
        )
        // Workers are numbered across groups.
        var workerNodes: [LinuxNodeProvisioner] = []
        for group in workers {
            for _ in 0..<group.count {
                workerNodes.append(
                    try LinuxNodeProvisioner(
                        name: ClusterHelper.workerName(cluster: name, index: workerNodes.count + 1),
                        clusterName: name,
                        roles: [StandardRoles.worker],
                        nodeImage: nodeImage,
                        cpus: group.cpus,
                        memory: group.memory,
                        virtualization: group.virtualization,
                        kernel: group.kernel,
                        registryScheme: registryFlags.scheme,
                        maxConcurrentDownloads: imageFetchFlags.maxConcurrentDownloads,
                        remove: remove,
                        containerSystemConfig: containerSystemConfig,
                        sharedImageStore: sharedImageStore
                    ))
            }
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
        _ = try await clusterClient.create(configuration: configuration)

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
