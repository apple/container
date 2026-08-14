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

import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Logging

/// A `NodeProvisioner` that runs a k8s node as a Linux container on the same host.
public struct LinuxNodeProvisioner: NodeProvisioner {
    public let roles: [String]

    private let clusterName: String
    private let nodeImage: String?
    private let cpus: Int64?
    private let memory: String?
    private let registryScheme: String
    private let maxConcurrentDownloads: Int
    private let remove: Bool
    private let fqdn: String?

    public init(
        clusterName: String,
        roles: [String] = [StandardRoles.controlPlane],
        nodeImage: String? = nil,
        cpus: Int64? = nil,
        memory: String? = nil,
        registryScheme: String = "https",
        maxConcurrentDownloads: Int = 3,
        remove: Bool = false,
        fqdn: String? = nil
    ) throws {
        guard !roles.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "LinuxNode roles must not be empty")
        }
        let known: Set<String> = [StandardRoles.controlPlane, StandardRoles.worker]
        let unrecognized = roles.filter { !known.contains($0) }
        guard unrecognized.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "LinuxNode roles contains unrecognized values: \(unrecognized.joined(separator: ", "))")
        }
        self.clusterName = clusterName
        self.roles = roles
        self.nodeImage = nodeImage
        self.cpus = cpus
        self.memory = memory
        self.registryScheme = registryScheme
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.remove = remove
        self.fqdn = fqdn
    }

    public func provision(name: String, log: Logger) async throws {
        let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()
        let resolvedImage = nodeImage ?? K8sHelper.nodeImage
        try await K8sHelper.ensureImage(nodeImage: resolvedImage, log: log, containerSystemConfig: containerSystemConfig)

        let isControlPlane = roles.contains(StandardRoles.controlPlane)
        let publishPorts = isControlPlane && fqdn == nil ? [try await K8sHelper.clusterPort()] : []

        let management = Flags.Management(
            arch: Arch.hostArchitecture().rawValue,
            capAdd: ["ALL"],
            capDrop: [],
            cidfile: "",
            detach: true,
            dns: .init(domain: nil, nameservers: [], options: [], searchDomains: []),
            dnsDisabled: false,
            entrypoint: nil,
            initImage: nil,
            kernel: nil,
            kernelArgs: [],
            labels: [
                "\(ResourceLabelKeys.plugin)=\(K8sHelper.pluginName)",
                "\(ResourceLabelKeys.role)=\(roles.joined(separator: ","))",
            ],
            maskedPaths: [],
            mounts: [],
            name: name,
            networks: [],
            os: "linux",
            platform: nil,
            publishPorts: publishPorts,
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

        let updatedResource = K8sHelper.defaultedResourceFlags(Flags.Resource(cpus: cpus, memory: memory))
        let processFlags = Flags.Process(
            cwd: nil,
            env: K8sHelper.nodeProxyEnv(),
            envFile: [],
            gid: nil,
            interactive: false,
            tty: false,
            uid: nil,
            ulimits: [],
            user: nil
        )

        var (config, kernel, initfs) = try await Utility.containerConfigFromFlags(
            id: name,
            image: resolvedImage,
            arguments: [],
            process: processFlags,
            management: management,
            resource: updatedResource,
            registry: Flags.Registry(scheme: registryScheme),
            imageFetch: Flags.ImageFetch(maxConcurrentDownloads: maxConcurrentDownloads),
            containerSystemConfig: containerSystemConfig,
            progressUpdate: { _ in },
            log: log
        )
        config.maskedPaths = []
        config.readonlyPaths = []

        let client = ContainerClient()
        try await client.create(
            configuration: config,
            options: ContainerCreateOptions(autoRemove: remove),
            kernel: kernel,
            initImage: initfs
        )

        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        let process = try await client.bootstrap(id: name, stdio: io.stdio)
        try await process.start()
        try io.closeAfterStart()

        try await K8sHelper.waitForNodeBooted(containerId: name, client: client, log: log)
    }

    public func address(name: String, log: Logger) async throws -> String {
        let client = ContainerClient()
        let snapshot = try await client.get(id: name)
        guard let ip = snapshot.networks.first?.ipv4Address.address.description else {
            throw ContainerizationError(.internalError, message: "no VM IP for node \(name)")
        }
        return ip
    }

    public func join(
        name: String,
        controlPlaneEndpoint: String,
        token: String,
        caCertHash: String,
        log: Logger
    ) async throws {
        let client = ContainerClient()
        try await K8sHelper.prepareNode(nodeID: name, client: client, log: log)

        let (code, output) = try await K8sHelper.execCapture(
            containerId: name,
            executable: K8sHelper.kubeadmPath,
            arguments: [
                "join", controlPlaneEndpoint,
                "--token", token,
                "--discovery-token-ca-cert-hash", caCertHash,
                "--ignore-preflight-errors", K8sHelper.ignorePreflightErrors,
                "--cri-socket", "unix:///run/containerd/containerd.sock",
            ],
            client: client)
        guard code == 0 else {
            throw ContainerizationError(.internalError, message: "kubeadm join failed on \(name): \(output)")
        }
    }

    public func waitForReady(name: String, log: Logger) async throws {
        let timeout = 180
        let client = ContainerClient()
        log.info("Waiting for node to become ready", metadata: ["node": "\(name)"])
        for attempt in 1...timeout {
            let code: Int32
            do {
                code = try await K8sHelper.runProbe(
                    client: client,
                    containerId: clusterName,
                    arguments: ["wait", "--for=condition=Ready", "node/\(name)", "--timeout=2s"])
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "node \(name) stopped unexpectedly while waiting for readiness: \(error)")
            }
            if code == 0 { return }
            if attempt == timeout {
                throw ContainerizationError(
                    .timeout,
                    message: "node \(name) did not become Ready within \(timeout * 2)s")
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    public func teardown(name: String, log: Logger) async throws {
        let client = ContainerClient()
        do {
            try? await client.stop(id: name)
            try await client.delete(id: name)
        } catch let error as ContainerizationError where error.code == .notFound {
            log.debug("node container not found, skipping delete", metadata: ["name": "\(name)"])
        }
    }
}
