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
import ContainerLog
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Darwin
import Foundation
import Logging
import TerminalProgress

public struct K8sCreate: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create and start a local Kubernetes cluster"
    )

    @Option(name: .long, help: "Cluster name (default: \(K8sHelper.defaultName))")
    var name: String = K8sHelper.defaultName

    @Flag(name: [.customLong("rm"), .long], help: "Remove the cluster container after it stops")
    var remove: Bool = false

    @OptionGroup(title: "Resource options")
    var resourceFlags: Flags.Resource

    @OptionGroup(title: "Registry options")
    var registryFlags: Flags.Registry

    @OptionGroup(title: "Image fetch options")
    var imageFetchFlags: Flags.ImageFetch

    @Option(help: "Node image reference (default: \(K8sHelper.nodeImage))")
    var nodeImage: String = K8sHelper.nodeImage

    public func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: K8sHelper.pluginName)

        guard ManagedContainer.nameValid(name) else {
            throw ContainerizationError(.invalidArgument, message: "cluster name \(name) is not a valid container ID")
        }

        let isTTY = isatty(FileHandle.standardError.fileDescriptor) == 1
        let progressConfig = try ProgressConfig(
            showSpinner: isTTY,
            showTasks: true,
            showItems: true,
            ignoreSmallSize: true,
            totalTasks: 2,  // fetch image, unpack image
            clearOnFinish: isTTY,
            outputMode: isTTY ? .ansi : .plain
        )

        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()

        let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()
        let fqdn = K8sHelper.fqdn(for: name, domain: containerSystemConfig.dns.domain)

        let provisioner = try LinuxNodeProvisioner(
            clusterName: name,
            roles: [StandardRoles.controlPlane, StandardRoles.worker],
            nodeImage: nodeImage,
            cpus: resourceFlags.cpus,
            memory: resourceFlags.memory,
            registryScheme: registryFlags.scheme,
            maxConcurrentDownloads: imageFetchFlags.maxConcurrentDownloads,
            remove: remove,
            fqdn: fqdn
        )

        progress.set(description: "Starting cluster")
        try await provisioner.provision(name: name, log: log)

        let client = ContainerClient()
        do {
            let vmIP = try await provisioner.address(name: name, log: log)
            var sans = ["127.0.0.1"]
            if let fqdn { sans.append(contentsOf: [vmIP, fqdn]) }

            progress.set(description: "Running kubeadm init")
            try await K8sHelper.prepareNode(nodeID: name, client: client, log: log)
            try await K8sHelper.bootstrapControlPlane(
                nodeID: name, apiServerSANs: sans, advertiseAddress: vmIP,
                schedulable: provisioner.roles.contains(StandardRoles.worker),
                client: client, log: log)

            progress.set(description: "Waiting for cluster to be ready")
            try await K8sHelper.waitForReady(containerId: name, client: client, log: log)

            progress.set(description: "Writing kubeconfig")
            do {
                let rawConfig = try await K8sHelper.fetchConfig(containerId: name, client: client, log: log)
                let kubeConfig = try await K8sHelper.transformConfig(rawConfig, containerId: name, fqdn: fqdn, client: client)
                try K8sHelper.mergeConfig(kubeConfig, containerId: name, setCurrentContext: true, log: log)
            } catch {
                log.warning("failed to write kubeconfig", metadata: ["name": "\(name)", "error": "\(error)"])
                log.info("cluster is running; use 'container k8s write-config --name \(name)' to write the kubeconfig")
            }
        } catch {
            try? await provisioner.teardown(name: name, log: log)
            try? K8sHelper.removeConfig(containerId: name, log: log)
            throw error
        }

        progress.finish()
        print(name)
    }
}
