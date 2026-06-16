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
import ContainerXPC
import ContainerizationError
import ContainerizationOCI
import Foundation
import TerminalProgress

/// A client for interacting with the container machine API server.
public struct MachineClient: Sendable {
    public static let serviceIdentifier = "com.apple.container.core.machine-apiserver"

    public static func machineConfigFromFlags(
        id: String,
        image: String,
        management: Flags.MachineManagement,
        registry: Flags.Registry,
        imageFetch: Flags.ImageFetch,
        containerSystemConfig: ContainerSystemConfig,
        progressUpdate: @escaping ProgressUpdateHandler
    ) async throws -> (MachineConfiguration, MachineResources?) {
        var requestedPlatform = Parser.platform(os: management.os, arch: management.arch)
        // Prefer --platform
        if let platform = management.platform {
            requestedPlatform = try Parser.platform(from: platform)
        }
        let scheme = try RequestScheme(registry.scheme)

        await progressUpdate([
            .setDescription("Fetching image"),
            .setItemsName("blobs"),
        ])
        let taskManager = ProgressTaskCoordinator()
        let fetchTask = await taskManager.startTask()
        let img = try await ClientImage.fetch(
            reference: image,
            platform: requestedPlatform,
            scheme: scheme,
            containerSystemConfig: containerSystemConfig,
            progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progressUpdate),
            maxConcurrentDownloads: imageFetch.maxConcurrentDownloads
        )

        // Unpack a fetched image before use
        await progressUpdate([
            .setDescription("Unpacking image"),
            .setItemsName("entries"),
        ])
        let unpackTask = await taskManager.startTask()
        try await img.getCreateSnapshot(
            platform: requestedPlatform,
            progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progressUpdate))

        let userSetup = UserSetup(
            username: NSUserName(),
            uid: getuid(),
            gid: getgid())

        let config = try MachineConfiguration(
            id: id,
            image: img.description,
            platform: requestedPlatform,
            userSetup: userSetup)

        let resources = try? await Self.fetchMachineArtifact(
            reference: img.reference, platform: requestedPlatform, scheme: scheme)

        return (config, resources)
    }

    private let xpcClient: XPCClient

    public init() {
        self.xpcClient = XPCClient(service: Self.serviceIdentifier)
    }

    @discardableResult
    private func xpcSend(
        message: XPCMessage,
        timeout: Duration? = .seconds(10)
    ) async throws -> XPCMessage {
        try await xpcClient.send(message, responseTimeout: timeout)
    }

    /// List container machines
    public func list() async throws -> [MachineSnapshot] {
        do {
            let request = XPCMessage(route: MachineRoutes.listMachine.rawValue)

            let response = try await xpcSend(
                message: request,
                timeout: .seconds(10)
            )
            let data = response.dataNoCopy(key: MachineKeys.machines.rawValue)
            guard let data else {
                return []
            }
            return try JSONDecoder().decode([MachineSnapshot].self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to list container machines",
                cause: error
            )
        }
    }

    /// Create a new container machine with the given configuration
    public func create(
        configuration: MachineConfiguration,
        resources: MachineResources?,
        bootConfig: MachineConfig,
    ) async throws {
        do {
            let request = XPCMessage(route: MachineRoutes.createMachine.rawValue)

            let config = try JSONEncoder().encode(configuration)
            request.set(key: MachineKeys.machineConfig.rawValue, value: config)

            if let resources {
                let data = try JSONEncoder().encode(resources)
                request.set(key: MachineKeys.machineResources.rawValue, value: data)
            }

            let bootData = try JSONEncoder().encode(bootConfig)
            request.set(key: MachineKeys.bootConfig.rawValue, value: bootData)

            let _ = try await xpcSend(message: request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create container machine",
                cause: error
            )
        }
    }

    /// Delete the container machine along with any resources.
    public func delete(id: String) async throws {
        do {
            let request = XPCMessage(route: MachineRoutes.deleteMachine.rawValue)
            request.set(key: MachineKeys.id.rawValue, value: id)

            let _ = try await xpcSend(message: request, timeout: .seconds(15))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to delete container machine",
                cause: error
            )
        }
    }

    /// Get the default container machine.
    public func getDefault() async throws -> String? {
        do {
            let request = XPCMessage(route: MachineRoutes.getDefault.rawValue)

            let response = try await xpcSend(message: request)
            let id = response.string(key: MachineKeys.id.rawValue)
            guard let id else {
                return nil
            }

            return id
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get the default container machine",
                cause: error
            )
        }
    }

    /// Set a default container machine.
    public func setDefault(id: String) async throws {
        do {
            let request = XPCMessage(route: MachineRoutes.setDefault.rawValue)
            request.set(key: MachineKeys.id.rawValue, value: id)

            let _ = try await xpcSend(message: request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to set a default container machine",
                cause: error
            )
        }
    }

    /// Boot a container machine.
    public func boot(id: String?, dynamicEnv: [String: String] = [:]) async throws -> MachineSnapshot {
        do {
            let request = XPCMessage(route: MachineRoutes.bootMachine.rawValue)
            if let id {
                request.set(key: MachineKeys.id.rawValue, value: id)
            }

            let dynamicEnvData = try JSONEncoder().encode(dynamicEnv)
            request.set(key: MachineKeys.dynamicEnv.rawValue, value: dynamicEnvData)

            let response = try await xpcSend(message: request)
            guard let data = response.dataNoCopy(key: MachineKeys.snapshot.rawValue) else {
                throw ContainerizationError(
                    .internalError,
                    message: "missing snapshot in response"
                )
            }
            return try JSONDecoder().decode(MachineSnapshot.self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to boot container machine",
                cause: error
            )
        }
    }

    /// Stop a running container machine.
    public func stop(id: String) async throws {
        do {
            let request = XPCMessage(route: MachineRoutes.stopMachine.rawValue)
            request.set(key: MachineKeys.id.rawValue, value: id)

            let _ = try await xpcSend(message: request, timeout: .seconds(30))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stop container machine",
                cause: error
            )
        }
    }

    /// Set boot-time config for a container machine.
    public func setConfig(id: String, bootConfig: MachineConfig) async throws {
        do {
            let request = XPCMessage(route: MachineRoutes.setConfig.rawValue)
            request.set(key: MachineKeys.id.rawValue, value: id)
            let data = try JSONEncoder().encode(bootConfig)
            request.set(key: MachineKeys.bootConfig.rawValue, value: data)
            let _ = try await xpcSend(message: request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to set container machine config",
                cause: error
            )
        }
    }

    /// Inspect a container machine and return its snapshot.
    public func inspect(id: String) async throws -> MachineSnapshot {
        do {
            let request = XPCMessage(route: MachineRoutes.inspectMachine.rawValue)
            request.set(key: MachineKeys.id.rawValue, value: id)

            let response = try await xpcSend(message: request)
            guard let data = response.dataNoCopy(key: MachineKeys.snapshot.rawValue) else {
                throw ContainerizationError(
                    .internalError,
                    message: "missing snapshot in response"
                )
            }
            return try JSONDecoder().decode(MachineSnapshot.self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to inspect container machine",
                cause: error
            )
        }
    }

    /// Get the log file handles for a container machine.
    public func logs(id: String) async throws -> [FileHandle] {
        do {
            let request = XPCMessage(route: MachineRoutes.logsMachine.rawValue)
            request.set(key: MachineKeys.id.rawValue, value: id)

            let response = try await xpcSend(message: request)
            let fds = response.fileHandles(key: MachineKeys.logs.rawValue)
            guard let fds else {
                throw ContainerizationError(
                    .internalError,
                    message: "no log fds returned"
                )
            }
            return fds
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get logs for container machine \(id)",
                cause: error
            )
        }
    }
}

// MARK: Container machine artifact fetching

extension MachineClient {
    /// Fetch machine metadata from an OCI artifact attached to an image via the referrers API.
    ///
    /// Returns `nil` if no artifact is found or the registry doesn't support referrers.
    static func fetchMachineArtifact(
        reference: String,
        platform: Platform,
        scheme: RequestScheme
    ) async throws -> MachineResources? {
        let ref = try Reference.parse(reference)
        guard let domain = ref.resolvedDomain else {
            return nil
        }

        let insecure = try scheme.schemeFor(host: ref.resolvedDomain ?? "", internalDnsDomain: nil) == .http

        // Look up credentials from keychain
        let keychain = KeychainHelper(securityDomain: Constants.keychainID)
        let auth = try? keychain.lookup(hostname: domain)

        let client = try RegistryClient(reference: reference, insecure: insecure, auth: auth)
        let name = ref.path

        // Resolve the image reference to get the manifest digest.
        // We need the platform-specific manifest digest, not the index digest.
        let tag = ref.digest ?? ref.tag ?? "latest"
        let topDescriptor = try await client.resolve(name: name, tag: tag)

        // If the top-level is an index, find the platform-specific manifest
        let manifestDigest: String
        switch topDescriptor.mediaType {
        case MediaTypes.index, MediaTypes.dockerManifest:
            let index: Index = try await client.fetch(name: name, descriptor: topDescriptor)
            guard let platformDesc = index.manifests.first(where: { $0.platform == platform }) else {
                return nil
            }
            manifestDigest = platformDesc.digest
        case MediaTypes.imageManifest:
            manifestDigest = topDescriptor.digest
        default:
            return nil
        }

        // Query referrers API for container machine config artifacts
        let referrersIndex = try await client.referrers(
            name: name,
            digest: manifestDigest,
            artifactType: MachineResources.configMediaType
        )

        guard let artifactDesc = referrersIndex.manifests.first else {
            return nil
        }

        // Fetch the artifact manifest
        let artifactManifest: Manifest = try await client.fetch(name: name, descriptor: artifactDesc)

        // Extract metadata JSON and setup script from artifact layers
        var resources: MachineResources?
        var setupScript: String?

        for layer in artifactManifest.layers {
            if layer.mediaType == MachineResources.configMediaType {
                let data = try await client.fetchData(name: name, descriptor: layer)
                resources = try JSONDecoder().decode(MachineResources.self, from: data)
            } else if layer.mediaType == MachineResources.setupScriptMediaType {
                let data = try await client.fetchData(name: name, descriptor: layer)
                let script = String(decoding: data, as: UTF8.self)
                if !script.isEmpty {
                    setupScript = script
                }
            }
        }

        if var resources, let setupScript {
            resources.setupScript = setupScript
        }

        return resources
    }
}
