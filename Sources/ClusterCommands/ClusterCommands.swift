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
import ContainerResource
import ContainerizationError
import Foundation
import Logging
import TerminalProgress

public protocol ClusterLoggableCommand: AsyncParsableCommand {
    var logOptions: Flags.Logging { get }
}

extension ClusterLoggableCommand {
    public var log: Logger {
        var logger = Logger(label: "cluster", factory: { _ in StderrLogHandler() })
        logger.logLevel = logOptions.debug ? .debug : .info
        return logger
    }
}

public struct ClusterCreate: ClusterLoggableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a Kubernetes cluster"
    )

    @OptionGroup
    public var logOptions: Flags.Logging

    @Option(name: .long, help: "Cluster name")
    var name: String = ClusterDefaults.clusterName

    @Option(name: .long, help: "Container image for the node")
    var image: String = ClusterDefaults.image

    @Option(name: .long, help: "Number of CPUs to allocate")
    var cpus: Int64 = ClusterDefaults.cpus

    @Option(name: .long, help: "Memory allocation (e.g. 8G, 16G)")
    var memory: String = ClusterDefaults.memory

    @Option(name: .long, help: "Pod network CIDR for kubeadm")
    var podCIDR: String = ClusterDefaults.podCIDR

    @Option(name: .long, help: "Kubernetes API server port")
    var apiPort: UInt16 = ClusterDefaults.apiPort

    @Option(name: .shortAndLong, help: "Path to kernel binary", completion: .file())
    var kernel: String?

    @Option(name: .long, help: "Write kubeconfig to this path")
    var kubeconfig: String?

    @Flag(name: .long, help: "Delete any existing cluster with the same name")
    var replace = false

    public func run() async throws {
        let spec = try ClusterSpec(
            name: name,
            image: image,
            cpus: cpus,
            memory: memory,
            podCIDR: podCIDR,
            apiPort: apiPort,
            kernelPath: kernel,
            kubeconfigPath: kubeconfig
        )

        try Utility.validEntityName(spec.nodeName)

        if let existing = try? await ClientContainer.get(id: spec.nodeName) {
            guard replace else {
                throw ContainerizationError(.exists, message: "cluster \(spec.name) already exists")
            }
            try await existing.delete(force: true)
        }

        let progressConfig = try ProgressConfig(
            showTasks: true,
            showItems: true,
            ignoreSmallSize: true,
            totalTasks: 6
        )
        let progress = ProgressBar(config: progressConfig)
        var progressFinished = false
        defer {
            if !progressFinished {
                progress.finish()
            }
        }
        progress.start()

        var processFlags = try Flags.Process.parse([])
        processFlags.env = ["KUBECONFIG=/etc/kubernetes/admin.conf"]

        var resourceFlags = try Flags.Resource.parse([])
        resourceFlags.cpus = spec.cpus
        resourceFlags.memory = spec.memory

        var managementFlags = try Flags.Management.parse([])
        managementFlags.name = spec.nodeName
        managementFlags.kernel = spec.kernelPath
        managementFlags.publishPorts = ["127.0.0.1:\(spec.apiPort):6443"]

        let registryFlags = try Flags.Registry.parse([])
        let imageFetchFlags = try Flags.ImageFetch.parse([])

        let (configuration, kernel) = try await Utility.containerConfigFromFlags(
            id: spec.nodeName,
            image: spec.image,
            arguments: [],
            process: processFlags,
            management: managementFlags,
            resource: resourceFlags,
            registry: registryFlags,
            imageFetch: imageFetchFlags,
            progressUpdate: progress.handler
        )

        progress.set(description: "Starting container")
        let container = try await ClientContainer.create(configuration: configuration, options: .default, kernel: kernel)
        try await ClusterContainer.bootstrapAndStart(container: container)
        progress.finish()
        progressFinished = true

        func runStep(_ label: String, command: [String]) async throws {
            if !logOptions.debug {
                print(label)
            }
            _ = try await ClusterExecutor.run(
                container: container,
                command: command,
                log: log,
                captureOutput: !logOptions.debug
            )
        }

        try await runStep("Configuring networking...", command: ["sysctl", "-w", "net.ipv4.ip_forward=1"])
        try await runStep(
            "Initializing kubeadm...",
            command: [
                "kubeadm",
                "init",
                "--pod-network-cidr=\(spec.podCIDR)",
                "--apiserver-cert-extra-sans=127.0.0.1",
            ]
        )

        let installCni = "sed -e 's@{{ .PodSubnet }}@\(spec.podCIDR)@' /kind/manifests/default-cni.yaml | kubectl apply -f -"
        try await runStep("Applying CNI...", command: ["/bin/sh", "-euc", installCni])

        _ = try? await ClusterExecutor.run(
            container: container,
            command: ["kubectl", "taint", "nodes", "--all", "node-role.kubernetes.io/control-plane-"],
            log: log,
            captureOutput: !logOptions.debug,
            allowFailure: true
        )

        let kubeconfigRaw = try await ClusterExecutor.run(
            container: container,
            command: ["cat", "/etc/kubernetes/admin.conf"],
            log: log,
            captureOutput: true
        )
        let kubeconfigPatched = KubeconfigManager.patch(
            raw: kubeconfigRaw.stdout,
            clusterName: spec.name,
            apiPort: spec.apiPort
        )
        try KubeconfigManager.write(config: kubeconfigPatched, to: spec.kubeconfigPath)

        let refreshed = try await ClientContainer.get(id: spec.nodeName)
        let nodeIP = refreshed.networks.first?.ipv4Address.address.description
        let apiServer = "https://127.0.0.1:\(spec.apiPort)"

        if !logOptions.debug {
            print("Cluster ready.")
        }
        print("\nCluster created.\n")
        print("  Name:       \(spec.name)")
        print("  Node:       \(spec.nodeName)")
        if let nodeIP {
            print("  Node IP:    \(nodeIP)")
            print("  HTTP/HTTPS: http://\(nodeIP) / https://\(nodeIP)")
        }
        print("  API server: \(apiServer)")
        print("  Kubeconfig: \(spec.kubeconfigPath.path)")
    }
}

public struct ClusterDelete: ClusterLoggableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a Kubernetes cluster"
    )

    @OptionGroup
    public var logOptions: Flags.Logging

    @Option(name: .long, help: "Cluster name")
    var name: String = ClusterDefaults.clusterName

    @Flag(name: .long, help: "Force delete the cluster")
    var force = false

    public func run() async throws {
        let nodeName = "\(name)-control-plane"
        do {
            let container = try await ClientContainer.get(id: nodeName)
            try await container.delete(force: force)
            print(nodeName)
        } catch let error as ContainerizationError where error.code == .notFound {
            if log.logLevel == .debug {
                log.debug("cluster \(name) not found")
            }
        }
    }
}

public struct ClusterStart: ClusterLoggableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a Kubernetes cluster"
    )

    @OptionGroup
    public var logOptions: Flags.Logging

    @Option(name: .long, help: "Cluster name")
    var name: String = ClusterDefaults.clusterName

    public func run() async throws {
        let nodeName = "\(name)-control-plane"
        let container = try await ClientContainer.get(id: nodeName)
        if container.status == .running {
            print(nodeName)
            return
        }
        try await ClusterContainer.bootstrapAndStart(container: container)
        print(nodeName)
    }
}

public struct ClusterStop: ClusterLoggableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a Kubernetes cluster"
    )

    @OptionGroup
    public var logOptions: Flags.Logging

    @Option(name: .long, help: "Cluster name")
    var name: String = ClusterDefaults.clusterName

    public func run() async throws {
        let nodeName = "\(name)-control-plane"
        let container = try await ClientContainer.get(id: nodeName)
        try await container.stop()
        print(nodeName)
    }
}

public struct ClusterStatus: ClusterLoggableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show cluster status"
    )

    @OptionGroup
    public var logOptions: Flags.Logging

    @Option(name: .long, help: "Cluster name")
    var name: String = ClusterDefaults.clusterName

    public func run() async throws {
        let nodeName = "\(name)-control-plane"
        let container = try await ClientContainer.get(id: nodeName)
        let nodeIP = container.networks.first?.ipv4Address.address.description
        let apiPort = container.configuration.publishedPorts.first(where: { $0.containerPort == 6443 })?.hostPort
        let kubeconfigPath = KubeconfigManager.resolvePath(path: nil, clusterName: name)

        print("Name:        \(name)")
        print("Node:        \(nodeName)")
        print("Status:      \(container.status.rawValue)")
        if let nodeIP {
            print("Node IP:     \(nodeIP)")
        }
        if let apiPort {
            print("API server:  https://127.0.0.1:\(apiPort)")
        }
        print("Kubeconfig:  \(kubeconfigPath.path)")
    }
}

public struct ClusterKubeconfig: ClusterLoggableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "kubeconfig",
        abstract: "Print or write kubeconfig"
    )

    @OptionGroup
    public var logOptions: Flags.Logging

    @Option(name: .long, help: "Cluster name")
    var name: String = ClusterDefaults.clusterName

    @Option(name: .long, help: "Write kubeconfig to this path")
    var kubeconfig: String?

    public func run() async throws {
        let nodeName = "\(name)-control-plane"
        let container = try await ClientContainer.get(id: nodeName)
        try ClusterContainer.ensureRunning(container)

        let apiPort: UInt16 =
            container.configuration.publishedPorts
            .first(where: { $0.containerPort == 6443 })?
            .hostPort ?? ClusterDefaults.apiPort

        let kubeconfigRaw = try await ClusterExecutor.run(
            container: container,
            command: ["cat", "/etc/kubernetes/admin.conf"],
            log: log,
            captureOutput: true
        )

        let kubeconfigPatched = KubeconfigManager.patch(
            raw: kubeconfigRaw.stdout,
            clusterName: name,
            apiPort: apiPort
        )

        if let kubeconfig {
            let path = KubeconfigManager.resolvePath(path: kubeconfig, clusterName: name)
            try KubeconfigManager.write(config: kubeconfigPatched, to: path)
            print(path.path)
        } else {
            print(kubeconfigPatched)
        }
    }
}
