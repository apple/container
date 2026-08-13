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
        try await K8sHelper.ensureImage(nodeImage: nodeImage, log: log, containerSystemConfig: containerSystemConfig)

        let fqdn = K8sHelper.fqdn(for: name, domain: containerSystemConfig.dns.domain)
        let dns = Flags.DNS(domain: nil, nameservers: [], options: [], searchDomains: [])

        let management = Flags.Management(
            arch: Arch.hostArchitecture().rawValue,
            capAdd: ["ALL"],
            capDrop: [],
            cidfile: "",
            detach: true,
            dns: dns,
            dnsDisabled: false,
            entrypoint: nil,
            initImage: nil,
            kernel: nil,
            kernelArgs: [],
            labels: [
                "\(ResourceLabelKeys.plugin)=\(K8sHelper.pluginName)",
                "\(ResourceLabelKeys.role)=\(K8sHelper.controlPlaneRoleName)",
            ],
            maskedPaths: [],
            mounts: [],
            name: name,
            networks: [],
            os: "linux",
            platform: nil,
            publishPorts: fqdn == nil ? [try await K8sHelper.clusterPort()] : [],
            publishSockets: [],
            readOnly: false,
            readonlyPaths: [],
            remove: remove,
            rosetta: true,
            runtime: nil,
            ssh: false,
            shmSize: nil,
            tmpFs: [],
            useInit: false,
            virtualization: false,
            volumes: []
        )

        let updatedResource = K8sHelper.defaultedResourceFlags(resourceFlags)
        let processFlags = Flags.Process(cwd: nil, env: K8sHelper.nodeProxyEnv(), envFile: [], gid: nil, interactive: false, tty: false, uid: nil, ulimits: [], user: nil)

        var (config, kernel, initfs) = try await Utility.containerConfigFromFlags(
            id: name,
            image: nodeImage,
            arguments: [],
            process: processFlags,
            management: management,
            resource: updatedResource,
            registry: registryFlags,
            imageFetch: imageFetchFlags,
            containerSystemConfig: containerSystemConfig,
            progressUpdate: progress.handler,
            log: log
        )

        // Allow the node to modify /proc/sys (e.g. net.ipv4.ip_forward) during setup.
        config.maskedPaths = []
        config.readonlyPaths = []

        let client = ContainerClient()
        let options = ContainerCreateOptions(autoRemove: remove)
        try await client.create(
            configuration: config,
            options: options,
            kernel: kernel,
            initImage: initfs
        )

        progress.set(description: "Starting cluster")
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        let process = try await client.bootstrap(id: name, stdio: io.stdio)
        try await process.start()
        try io.closeAfterStart()

        progress.set(description: "Waiting for node to boot")
        try await K8sHelper.waitForNodeBooted(containerId: name, client: client, log: log)

        let snapshot = try await client.get(id: name)
        guard let vmIP = snapshot.networks.first?.ipv4Address.address.description else {
            throw ContainerizationError(.internalError, message: "no VM IP for control plane \(name)")
        }
        var sans = ["127.0.0.1"]
        if let fqdn { sans.append(contentsOf: [vmIP, fqdn]) }

        progress.set(description: "Running kubeadm init")
        try await K8sHelper.prepareNode(nodeID: name, client: client, log: log)
        try await K8sHelper.bootstrapControlPlane(
            nodeID: name, apiServerSANs: sans, advertiseAddress: vmIP,
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

        progress.finish()
        print(name)
    }
}
