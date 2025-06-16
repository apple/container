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

import CVersion
import ContainerClient
import ContainerPlugin
import ContainerSandboxService
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging

actor ContainersService {
    private static let machServicePrefix = "com.apple.container"
    private static let launchdDomainString = try! ServiceManager.getDomainString()

    private let log: Logger
    private let containerRoot: URL
    private let pluginLoader: PluginLoader
    private let runtimePlugins: [Plugin]

    private let lock = AsyncLock()
    private var containers: [String: Item]

    struct Item: Sendable {
        let bundle: ContainerClient.Bundle
        var state: State

        enum State: Sendable {
            case dead
            case alive(SandboxClient)
            case exited(Int32)

            func isDead() -> Bool {
                switch self {
                case .dead: return true
                default: return false
                }
            }
        }
    }

    public init(root: URL, pluginLoader: PluginLoader, log: Logger) throws {
        let containerRoot = root.appendingPathComponent("containers")
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
        self.containerRoot = containerRoot
        self.pluginLoader = pluginLoader
        self.log = log
        self.runtimePlugins = pluginLoader.findPlugins().filter { $0.hasType(.runtime) }
        self.containers = try Self.loadAtBoot(root: containerRoot, loader: pluginLoader, log: log)
    }

    static func loadAtBoot(root: URL, loader: PluginLoader, log: Logger) throws -> [String: Item] {
        var directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        directories = directories.filter {
            $0.isDirectory
        }

        let runtimePlugins = loader.findPlugins().filter { $0.hasType(.runtime) }
        var results = [String: Item]()
        for dir in directories {
            do {
                let bundle = ContainerClient.Bundle(path: dir)
                let config = try bundle.configuration
                results[config.id] = .init(bundle: bundle, state: .dead)
                let plugin = runtimePlugins.first { $0.name == config.runtimeHandler }
                guard let plugin else {
                    throw ContainerizationError(.internalError, message: "Failed to find runtime plugin \(config.runtimeHandler)")
                }
                try Self.registerService(plugin: plugin, loader: loader, configuration: config, path: dir)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                log.warning("failed to load container bundle at \(dir.path)")
            }
        }
        return results
    }

    private func setContainer(_ id: String, _ item: Item, context: AsyncLock.Context) async {
        self.containers[id] = item
    }

    /// List all containers registered with the service.
    public func list() async throws -> [ContainerSnapshot] {
        self.log.debug("\(#function)")
        return await lock.withLock { context in
            var snapshots = [ContainerSnapshot]()

            for (id, item) in await self.containers {
                do {
                    let result = try await item.asSnapshot()
                    snapshots.append(result.0)
                } catch {
                    self.log.error("unable to load bundle for \(id) \(error)")
                }
            }
            return snapshots
        }
    }

    /// Create a new container from the provided id and configuration.
    public func create(configuration: ContainerConfiguration, kernel: Kernel, options: ContainerCreateOptions) async throws {
        self.log.debug("\(#function)")

        let runtimePlugin = self.runtimePlugins.filter {
            $0.name == configuration.runtimeHandler
        }.first
        guard let runtimePlugin else {
            throw ContainerizationError(.notFound, message: "unable to locate runtime plugin \(configuration.runtimeHandler)")
        }

        let path = self.containerRoot.appendingPathComponent(configuration.id)
        let systemPlatform = kernel.platform
        let initFs = try await getInitBlock(for: systemPlatform.ociPlatform())

        let bundle = try ContainerClient.Bundle.create(
            path: path,
            initialFilesystem: initFs,
            kernel: kernel,
            containerConfiguration: configuration
        )
        do {
            let containerImage = ClientImage(description: configuration.image)
            let imageFs = try await containerImage.getCreateSnapshot(platform: configuration.platform)
            try bundle.setContainerRootFs(cloning: imageFs)
            try bundle.write(filename: "options.json", value: options)

            try Self.registerService(
                plugin: runtimePlugin,
                loader: self.pluginLoader,
                configuration: configuration,
                path: path
            )
        } catch {
            do {
                try bundle.delete()
            } catch {
                self.log.error("failed to delete bundle for container \(configuration.id): \(error)")
            }
            throw error
        }
        self.containers[configuration.id] = Item(bundle: bundle, state: .dead)
    }

    private func getInitBlock(for platform: Platform) async throws -> Filesystem {
        let initImage = try await ClientImage.fetch(reference: ClientImage.initImageRef, platform: platform)
        var fs = try await initImage.getCreateSnapshot(platform: platform)
        fs.options = ["ro"]
        return fs
    }

    private static func registerService(
        plugin: Plugin,
        loader: PluginLoader,
        configuration: ContainerConfiguration,
        path: URL
    ) throws {
        let args = [
            "--root", path.path,
            "--uuid", configuration.id,
            "--debug",
        ]
        try loader.registerWithLaunchd(
            plugin: plugin,
            rootURL: path,
            args: args,
            instanceId: configuration.id
        )
    }

    private func get(id: String, context: AsyncLock.Context) throws -> Item {
        try self._get(id: id)
    }

    private func _get(id: String) throws -> Item {
        let item = self.containers[id]
        guard let item else {
            throw ContainerizationError(
                .notFound,
                message: "container with ID \(id) not found"
            )
        }
        return item
    }

    /// Delete a container and its resources.
    public func delete(id: String) async throws {
        self.log.debug("\(#function)")
        let item = try self._get(id: id)
        switch item.state {
        case .alive(let client):
            let state = try await client.state()
            if state.status == .running || state.status == .stopping {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(id) is not yet stopped and can not be deleted"
                )
            }
            try self._cleanup(id: id, item: item)
        case .dead, .exited(_):
            try self._cleanup(id: id, item: item)
        }
    }

    private static func fullLaunchdServiceLabel(runtimeName: String, instanceId: String) -> String {
        "\(Self.launchdDomainString)/\(Self.machServicePrefix).\(runtimeName).\(instanceId)"
    }

    private func _cleanup(id: String, item: Item) throws {
        self.log.debug("\(#function)")
        let config = try item.bundle.configuration
        let label = Self.fullLaunchdServiceLabel(runtimeName: config.runtimeHandler, instanceId: id)
        try ServiceManager.deregister(fullServiceLabel: label)
        try item.bundle.delete()
        self.containers.removeValue(forKey: id)
    }

    private func _shutdown(id: String, item: Item) throws {
        let config = try item.bundle.configuration
        let label = Self.fullLaunchdServiceLabel(runtimeName: config.runtimeHandler, instanceId: id)
        try ServiceManager.kill(fullServiceLabel: label)
    }

    private func cleanup(id: String, item: Item, context: AsyncLock.Context) async throws {
        try self._cleanup(id: id, item: item)
    }

    private func containerProcessExitHandler(_ id: String, _ exitCode: Int32, context: AsyncLock.Context) async {
        self.log.info("Handling container \(id) exit. Code \(exitCode)")
        do {
            var item = try self.get(id: id, context: context)
            switch item.state {
            case .dead, .exited(_):
                break
            case .alive(_):
                item.state = .exited(exitCode)
                await self.setContainer(id, item, context: context)
            }
            let options: ContainerCreateOptions = try item.bundle.load(filename: "options.json")
            if options.autoRemove {
                try await self.cleanup(id: id, item: item, context: context)
            }
        } catch {
            self.log.error(
                "Failed to handle container exit",
                metadata: [
                    "id": .string(id),
                    "error": .string(String(describing: error)),
                ])
        }
    }

    private func containerStartHandler(_ id: String, context: AsyncLock.Context) async throws {
        self.log.debug("\(#function)")
        self.log.info("Handling container \(id) Start.")
        do {
            var item = try self.get(id: id, context: context)
            let configuration = try item.bundle.configuration
            let client = SandboxClient(id: configuration.id, runtime: configuration.runtimeHandler)
            item.state = .alive(client)
            await self.setContainer(id, item, context: context)
        } catch {
            self.log.error(
                "Failed to handle container start",
                metadata: [
                    "id": .string(id),
                    "error": .string(String(describing: error)),
                ])
        }
    }
}

extension ContainersService {
    public func handleContainerEvents(event: ContainerEvent) async throws {
        self.log.debug("\(#function)")
        try await self.lock.withLock { context in
            switch event {
            case .containerExit(let id, let code):
                await self.containerProcessExitHandler(id, Int32(code), context: context)
            case .containerStart(let id):
                try await self.containerStartHandler(id, context: context)
            }
        }
    }

    /// Stop all containers inside the sandbox, aborting any processes currently
    /// executing inside the container, before stopping the underlying sandbox.
    public func stop(id: String, options: ContainerStopOptions) async throws {
        self.log.debug("\(#function)")
        try await lock.withLock { context in
            let item = try await self.get(id: id, context: context)
            switch item.state {
            case .dead, .exited(_):
                return
            case .alive(let client):
                try await client.stop(options: options)
            }
        }
    }

    public func logs(id: String) async throws -> [FileHandle] {
        self.log.debug("\(#function)")
        // Logs doesn't care if the container is running or not, just that
        // the bundle is there, and that the files actually exist.
        do {
            let item = try self._get(id: id)
            return [
                try FileHandle(forReadingFrom: item.bundle.containerLog),
                try FileHandle(forReadingFrom: item.bundle.bootlog),
            ]
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to open container logs: \(error)"
            )
        }
    }
}

extension ContainersService.Item {
    func asSnapshot() async throws -> (ContainerSnapshot, RuntimeStatus) {
        let config = try self.bundle.configuration

        switch self.state {
        case .dead, .exited(_):
            return (
                .init(
                    configuration: config,
                    status: RuntimeStatus.stopped,
                    networks: []
                ), .stopped
            )
        case .alive(let client):
            let state = try await client.state()
            return (
                .init(
                    configuration: config,
                    status: state.status,
                    networks: state.networks
                ), state.status
            )
        }
    }
}
