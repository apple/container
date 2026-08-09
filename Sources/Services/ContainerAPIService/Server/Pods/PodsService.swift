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
import ContainerPlugin
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging

/// Manages pods: machines that several containers run inside and share.
///
/// The verbs follow the runtime interface's sandbox lifecycle, which every
/// runtime serving Kubernetes implements, so what a pod does here is what a pod
/// does elsewhere.
/// https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto
public actor PodsService {
    struct PodState {
        var configuration: PodConfiguration
        var state: PodState.Lifecycle = .notReady
        var client: RuntimeClient? = nil
        var startedDate: Date? = nil

        enum Lifecycle {
            case notReady
            case ready
        }

        func getClient() throws -> RuntimeClient {
            guard let client else {
                throw ContainerizationError(
                    .invalidState,
                    message: "pod \(configuration.id) is not running"
                )
            }
            return client
        }
    }

    /// The runtime plugin a pod's machine is driven by.
    static let runtimeHandler = "container-runtime-linux"

    private static let machServicePrefix = "com.apple.container"

    /// The launchd domain, asked for once while the service is being built.
    ///
    /// Answering it runs `launchctl` and waits for it, which is a thread
    /// blocked until that process is done. Held in a stored property it is a
    /// wait the service makes as it is constructed; held in a static it would
    /// be made the first time a label is wanted, and the first time is inside
    /// a task, on a thread the concurrency pool needs back. That wait never
    /// ends, and because a static is initialized once every later caller waits
    /// on the same unfinished initialization, with nothing thrown and nothing
    /// logged to say so.
    private let launchdDomainString: String

    private static func fullLaunchdServiceLabel(domain: String, runtimeName: String, instanceId: String) -> String {
        "\(domain)/\(Self.machServicePrefix).\(runtimeName).\(instanceId)"
    }

    private let log: Logger
    private let debugHelpers: Bool
    private let podRoot: URL
    private let pluginLoader: PluginLoader
    private let runtimePlugins: [Plugin]
    private let containerSystemConfig: ContainerSystemConfig

    private let lock: AsyncLock
    private var pods: [String: PodState]

    // The containers a pod holds are the containers service's to know, so it
    // is asked rather than tracked twice.
    private weak var containersService: ContainersService?
    private weak var networksService: NetworksService?

    public init(
        appRoot: URL,
        pluginLoader: PluginLoader,
        containerSystemConfig: ContainerSystemConfig,
        debugHelpers: Bool = false,
        log: Logger
    ) throws {
        self.log = log
        self.debugHelpers = debugHelpers
        self.podRoot = appRoot.appendingPathComponent("pods")
        self.pluginLoader = pluginLoader
        self.runtimePlugins = pluginLoader.findPlugins().filter { $0.hasType(.runtime) }
        self.containerSystemConfig = containerSystemConfig
        self.lock = AsyncLock()
        self.launchdDomainString = try ServiceManager.getDomainString()
        self.pods = try Self.loadAtBoot(root: self.podRoot, log: log)
    }

    public func setContainersService(_ service: ContainersService) async {
        self.containersService = service
    }

    public func setNetworksService(_ service: NetworksService) async {
        self.networksService = service
    }

    /// The pods on disk, which outlive the process that made them.
    ///
    /// A pod's bundle is materialized by its machine's first boot, so a pod
    /// created and not yet booted has only the runtime configuration its
    /// create wrote; the pod's own configuration is read from whichever of
    /// the two holds it.
    static func loadAtBoot(root: URL, log: Logger) throws -> [String: PodState] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var pods: [String: PodState] = [:]
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for entry in entries {
            do {
                let bundle = ContainerResource.Bundle(path: entry)
                let configuration: PodConfiguration
                if bundle.isPod {
                    configuration = try bundle.podConfiguration
                } else if let embedded = try RuntimeConfiguration.readRuntimeConfiguration(from: entry).podConfiguration {
                    configuration = embedded
                } else {
                    log.warning("skipping a bundle that is not a pod's", metadata: ["path": "\(entry.path)"])
                    continue
                }
                pods[configuration.id] = PodState(configuration: configuration)
            } catch {
                log.warning("skipping unreadable pod", metadata: ["path": "\(entry.path)", "error": "\(error)"])
            }
        }
        return pods
    }

    /// Where a pod keeps what it is made of.
    public func path(for id: String) -> URL {
        self.podRoot.appendingPathComponent(id)
    }

    /// The boot log of the machine a pod runs.
    ///
    /// The machine is the pod's rather than any one container's: every
    /// container the pod holds boots on it, and one log records that boot, so
    /// the pod is what answers for it.
    public func bootLog(for id: String) throws -> FileHandle {
        let bundle = ContainerResource.Bundle(path: self.path(for: id))
        return try FileHandle(forReadingFrom: bundle.bootlog)
    }

    /// The client for the machine a pod runs, which its containers are
    /// reached through.
    public func client(for id: String) throws -> RuntimeClient {
        try self._getPodState(id: id).getClient()
    }

    /// The initial filesystem a pod's machine boots, which holds the agent.
    private func getInitBlock(for platform: Platform, imageRef: String? = nil) async throws -> Filesystem {
        let ref = imageRef ?? containerSystemConfig.vminit.image
        let initImage = try await ClientImage.fetch(reference: ref, platform: platform, containerSystemConfig: containerSystemConfig)
        var fs = try await initImage.getCreateSnapshot(platform: platform)
        fs.options = ["ro"]
        return fs
    }

    /// Write down a pod that boots the init image named, or the default one.
    public func create(configuration: PodConfiguration, kernel: Kernel, initImage: String? = nil) async throws {
        try await self.create(
            configuration: configuration,
            kernel: kernel,
            initialFilesystem: try await self.getInitBlock(for: kernel.platform.ociPlatform(), imageRef: initImage)
        )
    }

    /// Write down a pod, so containers can be placed in it before it boots.
    ///
    /// A caller holding the init filesystem already, such as one making the pod
    /// for a container whose own init image was resolved when it was created,
    /// passes it here rather than naming an image to resolve again.
    public func create(configuration: PodConfiguration, kernel: Kernel, initialFilesystem: Filesystem) async throws {
        log.debug(
            "PodsService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(configuration.id)",
            ]
        )
        defer {
            log.debug(
                "PodsService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(configuration.id)",
                ]
            )
        }

        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(configuration.id)"]) { context in
            guard await self.pods[configuration.id] == nil else {
                throw ContainerizationError(.exists, message: "pod already exists: \(configuration.id)")
            }

            // A name on a network answers for one thing on it. The names live
            // on the attachments a pod holds, since the pod holds the network
            // its containers share, so it is here that two of them are kept
            // from answering to the same one, which is what a container with a
            // machine of its own was held to when it held its own attachments.
            var taken = Set<String>()
            for pod in await self.pods.values {
                for attachment in pod.configuration.networks {
                    taken.insert(attachment.options.hostname)
                }
            }
            let clashing = configuration.networks.map { $0.options.hostname }.filter { taken.contains($0) }
            guard clashing.isEmpty else {
                throw ContainerizationError(.exists, message: "hostname(s) already exist: \(clashing)")
            }

            guard self.runtimePlugins.first(where: { $0.name == configuration.runtimeHandler }) != nil else {
                throw ContainerizationError(
                    .notFound,
                    message: "unable to locate runtime plugin \(configuration.runtimeHandler)"
                )
            }

            // The floor a machine needs to boot at all, the same one a
            // container with a machine of its own is held to.
            let minimumMemory: UInt64 = 200.mib()
            guard configuration.resources.memoryInBytes >= minimumMemory else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "minimum memory amount allowed is 200 MiB (got \(configuration.resources.memoryInBytes) bytes)"
                )
            }

            let path = await self.path(for: configuration.id)
            let runtimeConfig = RuntimeConfiguration(
                path: path,
                initialFilesystem: initialFilesystem,
                kernel: kernel,
                podConfiguration: configuration
            )
            try runtimeConfig.writeRuntimeConfiguration()

            await self.setPodState(configuration.id, PodState(configuration: configuration), context: context)
        }
    }

    /// What a caller holds on behalf of a container it is starting a pod for.
    ///
    /// A container placed in a pod is given these as it goes in, the way a
    /// container with a machine of its own is given them as the machine is
    /// bootstrapped. They belong to the container rather than to the pod, so
    /// they travel under its id.
    public struct ContainerStartup: Sendable {
        /// The streams the caller opened for the container.
        public var stdio: [FileHandle?]
        /// The environment the caller was asked to add to the container's.
        public var dynamicEnv: [String: String]

        public init(stdio: [FileHandle?], dynamicEnv: [String: String] = [:]) {
            self.stdio = stdio
            self.dynamicEnv = dynamicEnv
        }
    }

    /// Boot a pod's machine and place the containers that belong to it inside.
    ///
    /// The containers go in before the machine starts, which is what a machine
    /// with no way to attach storage while running requires.
    ///
    /// A container the caller is starting the pod for brings what the caller
    /// holds for it. The machine itself is nobody's to read and has no
    /// environment of its own, so it is bootstrapped with neither.
    /// The bundles of the containers a pod holds, which its machine runs.
    private func bundlePaths(of id: String) async throws -> [String] {
        var paths = [String]()
        for member in await self.containers(of: id) {
            guard let path = await self.containersService?.path(for: member.id) else {
                throw ContainerizationError(.internalError, message: "no container service to place \(member.id)")
            }
            paths.append(path.path)
        }
        return paths
    }

    public func start(id: String, container: String? = nil, startup: ContainerStartup? = nil) async throws {
        log.debug("PodsService: enter", metadata: ["func": "\(#function)", "id": "\(id)"])
        defer { log.debug("PodsService: exit", metadata: ["func": "\(#function)", "id": "\(id)"]) }

        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            var state = try await self._getPodState(id: id)
            var running = state.client

            // A machine can be gone while the service that ran it lingers:
            // stopped out of band, crashed, or torn down without the pod
            // hearing of it. A pod that offered that machine would be
            // offering one that is not there, so the client is believed only
            // while its machine answers running; otherwise the service is
            // taken down and the pod boots a fresh machine the way it booted
            // the first.
            if let held = running, (try? await held.state())?.status != .running {
                await self.deregister(id: id)
                state.client = nil
                state.state = .notReady
                state.startedDate = nil
                await self.setPodState(id, state, context: context)
                running = nil
            }

            do {
                let client: RuntimeClient
                var networkBootstrapInfos = [NetworkBootstrapInfo]()
                if let running {
                    client = running
                } else {
                    let path = await self.path(for: id)
                    let runtime = state.configuration.runtimeHandler
                    guard let plugin = self.runtimePlugins.first(where: { $0.name == runtime }) else {
                        throw ContainerizationError(.notFound, message: "unable to locate runtime plugin \(runtime)")
                    }
                    try Self.registerService(
                        plugin: plugin,
                        loader: self.pluginLoader,
                        id: id,
                        path: path,
                        debug: self.debugHelpers,
                        domain: self.launchdDomainString
                    )

                    // The pod claims its addresses, which every container placed
                    // in it shares, having no network namespace of its own.
                    for n in state.configuration.networks {
                        guard let plugin = try await self.networksService?.plugin(for: n.network) else {
                            throw ContainerizationError(.internalError, message: "failed to get plugin for network \(n.network)")
                        }
                        networkBootstrapInfos.append(NetworkBootstrapInfo(plugin: plugin))
                    }
                    client = try await RuntimeClient.create(id: id, runtime: runtime)
                }

                // The pod is asked to run holding its containers, which is one
                // request whether it is coming up around them or already up and
                // taking in the one that is new to it.
                try await client.bootstrap(
                    bundlePaths: try await self.bundlePaths(of: id),
                    stdioFor: container,
                    stdio: startup?.stdio ?? [nil, nil, nil],
                    networkBootstrapInfos: networkBootstrapInfos,
                    dynamicEnv: startup?.dynamicEnv ?? [:]
                )

                if running == nil {
                    state.client = client
                    state.state = .ready
                    state.startedDate = Date()
                    await self.setPodState(id, state, context: context)
                }
            } catch {
                if running == nil {
                    await self.deregister(id: id)
                }
                throw error
            }
        }
    }

    /// Stop a pod's machine, and with it every container inside.
    public func stop(id: String, options: ContainerStopOptions = ContainerStopOptions(timeoutInSeconds: 5, signal: "SIGTERM")) async throws {
        log.debug("PodsService: enter", metadata: ["func": "\(#function)", "id": "\(id)"])
        defer { log.debug("PodsService: exit", metadata: ["func": "\(#function)", "id": "\(id)"]) }

        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            var state = try await self._getPodState(id: id)
            guard let client = state.client else {
                return
            }

            try? await client.stop(options: options)
            try? await client.shutdown()
            await self.deregister(id: id)

            state.client = nil
            state.state = .notReady
            state.startedDate = nil
            await self.setPodState(id, state, context: context)
        }
    }

    /// Take a pod away. A pod still holding containers is kept unless the
    /// caller insists, in which case the containers go with it.
    public func delete(id: String, force: Bool) async throws {
        log.debug("PodsService: enter", metadata: ["func": "\(#function)", "id": "\(id)"])
        defer { log.debug("PodsService: exit", metadata: ["func": "\(#function)", "id": "\(id)"]) }

        let members = await self.containers(of: id)
        if !members.isEmpty {
            guard force else {
                throw ContainerizationError(
                    .invalidState,
                    message: "pod \(id) holds \(members.count) container(s); stop and remove them, or force"
                )
            }
            for member in members {
                try await self.containersService?.delete(id: member.id, force: true)
            }
        }

        // Taking the last container out of a pod that was made for one is what
        // takes that pod away, so the members above may have carried this pod
        // off as they went. A pod already gone is what the caller asked for.
        guard (try? self._getPodState(id: id)) != nil else {
            return
        }

        try await self.stop(id: id)
        await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            try? FileManager.default.removeItem(at: await self.path(for: id))
            await self.removePodState(id, context: context)
        }
    }

    /// Everything known about a pod, including the containers in it.
    public func inspect(id: String) async throws -> PodSnapshot {
        let state = try self._getPodState(id: id)
        return await self.snapshot(state)
    }

    /// Every pod, in a settled order.
    public func list() async -> [PodSnapshot] {
        var snapshots: [PodSnapshot] = []
        for state in self.pods.values.sorted(by: { $0.configuration.id < $1.configuration.id }) {
            snapshots.append(await self.snapshot(state))
        }
        return snapshots
    }

    /// Hold a running pod to a memory size, which its containers share.
    ///
    /// This is the runtime interface's `UpdatePodSandboxResources` for the one
    /// resource a running machine can be held to after it has booted.
    public func update(id: String, memoryInBytes: UInt64) async throws {
        let state = try self._getPodState(id: id)
        let client = try state.getClient()
        try await client.setTargetMemorySize(memoryInBytes)
    }

    /// Take away a pod a container was given for itself.
    ///
    /// A container took its machine down as it was removed, by deregistering the
    /// service that ran it, because the machine was the container's and nothing
    /// else could be in it. A pod nobody named holds the machine in its place
    /// and exists because the container needed one, so it goes the same way.
    ///
    /// A pod someone named was not given to this container. It was there before
    /// the container and is there after, so a container leaving says nothing
    /// about it. Neither does a container leaving one that others are still in:
    /// a container may be placed in a pod it was given the name of, anonymous
    /// or not, and holds it up the way any other in it would.
    ///
    /// What a pod holds is what the containers say they are in, so this is
    /// asked with the container lock held by a caller that has already taken
    /// its own container out of it. Held that way the answer cannot change
    /// between the asking and the removal, since a container joins a pod only
    /// by being created.
    public func removeIfAnonymous(id: String) async {
        guard let state = try? self._getPodState(id: id), state.configuration.isAnonymous else {
            return
        }
        guard await self.containers(of: id).isEmpty else {
            return
        }
        do {
            try await self.delete(id: id, force: true)
        } catch {
            self.log.error(
                "failed to remove the machine a container had to itself",
                metadata: ["pod": "\(id)", "error": "\(error)"])
        }
    }

    private func snapshot(_ state: PodState) async -> PodSnapshot {
        let members = await self.containers(of: state.configuration.id)
        var networks: [Attachment] = []
        // A pod is ready when its machine is running, which is what the machine
        // says rather than what it was last told to do: the machine goes down on
        // its own once the last container in it has stopped, and a pod that
        // answered ready after that would be offering a machine that is not
        // there.
        var running = false
        if let client = state.client, let sandbox = try? await client.state() {
            networks = sandbox.networks
            running = sandbox.status == .running
        }
        return PodSnapshot(
            configuration: state.configuration,
            state: state.state == .ready && running ? .ready : .notReady,
            networks: networks,
            containers: members.map { $0.id }.sorted(),
            startedDate: state.startedDate
        )
    }

    private func containers(of id: String) async -> [ContainerSnapshot] {
        guard let containersService = self.containersService else {
            return []
        }
        let all = (try? await containersService.list()) ?? []
        return all.filter { $0.configuration.pod == id }
    }

    private static func registerService(
        plugin: Plugin,
        loader: PluginLoader,
        id: String,
        path: URL,
        debug: Bool,
        domain: String
    ) throws {
        let args = [
            "start",
            "--root", path.path,
            "--uuid", id,
            debug ? "--debug" : nil,
        ].compactMap { $0 }
        try loader.registerWithLaunchd(
            plugin: plugin,
            pluginStateRoot: path,
            args: args,
            instanceId: id
        )
    }

    private func deregister(id: String) async {
        let runtime = (try? self._getPodState(id: id).configuration.runtimeHandler) ?? Self.runtimeHandler
        let label = Self.fullLaunchdServiceLabel(
            domain: self.launchdDomainString, runtimeName: runtime, instanceId: id)
        try? ServiceManager.deregister(fullServiceLabel: label)
    }

    private func setPodState(_ id: String, _ state: PodState, context: AsyncLock.Context) async {
        self.pods[id] = state
    }

    private func removePodState(_ id: String, context: AsyncLock.Context) async {
        self.pods.removeValue(forKey: id)
    }

    private func _getPodState(id: String) throws -> PodState {
        guard let state = self.pods[id] else {
            throw ContainerizationError(.notFound, message: "pod with ID \(id) not found")
        }
        return state
    }
}
