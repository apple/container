//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import ContainerNetworkService
import ContainerPersistence
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import TerminalProgress

public struct Utility {
    private static let infraImages = [
        DefaultsStore.get(key: .defaultBuilderImage),
        DefaultsStore.get(key: .defaultInitImage),
    ]

    public static func createContainerID(name: String?) -> String {
        guard let name else {
            return UUID().uuidString.lowercased()
        }
        return name
    }

    public static func isInfraImage(name: String) -> Bool {
        for infraImage in infraImages {
            if name == infraImage {
                return true
            }
        }
        return false
    }

    public static func trimDigest(digest: String) -> String {
        var digest = digest
        digest.trimPrefix("sha256:")
        if digest.count > 24 {
            digest = String(digest.prefix(24)) + "..."
        }
        return digest
    }

    public static func validEntityName(_ name: String) throws {
        let pattern = #"^[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#
        let regex = try Regex(pattern)
        if try regex.firstMatch(in: name) == nil {
            throw ContainerizationError(.invalidArgument, message: "invalid entity name \(name)")
        }
    }

    public static func containerConfigFromFlags(
        id: String,
        image: String,
        arguments: [String],
        process: Flags.Process,
        management: Flags.Management,
        resource: Flags.Resource,
        registry: Flags.Registry,
        progressUpdate: @escaping ProgressUpdateHandler
    ) async throws -> (ContainerConfiguration, Kernel) {
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
            progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progressUpdate)
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

        await progressUpdate([
            .setDescription("Fetching kernel"),
            .setItemsName("binary"),
        ])

        let kernel = try await self.getKernel(management: management)

        // Pull and unpack the initial filesystem
        await progressUpdate([
            .setDescription("Fetching init image"),
            .setItemsName("blobs"),
        ])
        let fetchInitTask = await taskManager.startTask()
        let initImage = try await ClientImage.fetch(
            reference: ClientImage.initImageRef, platform: .current, scheme: scheme,
            progressUpdate: ProgressTaskCoordinator.handler(for: fetchInitTask, from: progressUpdate))

        await progressUpdate([
            .setDescription("Unpacking init image"),
            .setItemsName("entries"),
        ])
        let unpackInitTask = await taskManager.startTask()
        _ = try await initImage.getCreateSnapshot(
            platform: .current,
            progressUpdate: ProgressTaskCoordinator.handler(for: unpackInitTask, from: progressUpdate))

        await taskManager.finish()

        let imageConfig = try await img.config(for: requestedPlatform).config
        let description = img.description
        let pc = try Parser.process(
            arguments: arguments,
            processFlags: process,
            managementFlags: management,
            config: imageConfig
        )

        var config = ContainerConfiguration(id: id, image: description, process: pc)
        config.platform = requestedPlatform

        config.resources = try Parser.resources(
            cpus: resource.cpus,
            memory: resource.memory
        )

        let tmpfs = try Parser.tmpfsMounts(management.tmpFs)
        let volumesOrFs = try Parser.volumes(management.volumes)
        let mountsOrFs = try Parser.mounts(management.mounts)

        var resolvedMounts: [Filesystem] = []
        resolvedMounts.append(contentsOf: tmpfs)

        // Resolve volumes and filesystems
        for item in (volumesOrFs + mountsOrFs) {
            switch item {
            case .filesystem(let fs):
                resolvedMounts.append(fs)
            case .volume(let parsed):
                do {
                    let volume = try await ClientVolume.inspect(parsed.name)
                    let volumeMount = Filesystem.volume(
                        name: parsed.name,
                        format: volume.format,
                        source: volume.source,
                        destination: parsed.destination,
                        options: parsed.options
                    )
                    resolvedMounts.append(volumeMount)
                } catch {
                    throw ContainerizationError(.invalidArgument, message: "volume '\(parsed.name)' not found")
                }
            }
        }

        config.mounts = resolvedMounts

        config.virtualization = management.virtualization

        config.networks = try getAttachmentConfigurations(containerId: config.id, networkIds: management.networks)
        for attachmentConfiguration in config.networks {
            let network: NetworkState = try await ClientNetwork.get(id: attachmentConfiguration.network)
            guard case .running(_, _) = network else {
                throw ContainerizationError(.invalidState, message: "network \(attachmentConfiguration.network) is not running")
            }
        }

        if management.dnsDisabled {
            config.dns = nil
        } else {
            let domain = management.dnsDomain ?? DefaultsStore.getOptional(key: .defaultDNSDomain)
            config.dns = .init(
                nameservers: management.dnsNameservers,
                domain: domain,
                searchDomains: management.dnsSearchDomains,
                options: management.dnsOptions
            )
        }

        if Platform.current.architecture == "arm64" && requestedPlatform.architecture == "amd64" {
            config.rosetta = true
        }

        config.labels = try Parser.labels(management.labels)

        config.publishedPorts = try Parser.publishPorts(management.publishPorts)

        // Parse --publish-socket arguments and add to container configuration
        // to enable socket forwarding from container to host.
        config.publishedSockets = try Parser.publishSockets(management.publishSockets)

        config.ssh = management.ssh

        return (config, kernel)
    }

    static func getAttachmentConfigurations(containerId: String, networkIds: [String]) throws -> [AttachmentConfiguration] {
        // make an FQDN for the first interface
        let fqdn: String?
        if !containerId.contains(".") {
            // add default domain if it exists, and container ID is unqualified
            if let dnsDomain = DefaultsStore.getOptional(key: .defaultDNSDomain) {
                fqdn = "\(containerId).\(dnsDomain)."
            } else {
                fqdn = nil
            }
        } else {
            // use container ID directly if fully qualified
            fqdn = "\(containerId)."
        }

        guard networkIds.isEmpty else {
            // networks may only be specified for macOS 26+
            guard #available(macOS 26, *) else {
                throw ContainerizationError(.invalidArgument, message: "non-default network configuration requires macOS 26 or newer")
            }

            // attach the first network using the fqdn, and the rest using just the container ID
            return networkIds.enumerated().map { item in
                guard item.offset == 0 else {
                    return AttachmentConfiguration(network: item.element, options: AttachmentOptions(hostname: containerId))
                }
                return AttachmentConfiguration(network: item.element, options: AttachmentOptions(hostname: fqdn ?? containerId))
            }
        }
        // if no networks specified, attach to the default network
        return [AttachmentConfiguration(network: ClientNetwork.defaultNetworkName, options: AttachmentOptions(hostname: fqdn ?? containerId))]
    }

    private static func getKernel(management: Flags.Management) async throws -> Kernel {
        // For the image itself we'll take the user input and try with it as we can do userspace
        // emulation for x86, but for the kernel we need it to match the hosts architecture.
        let s: SystemPlatform = .current
        if let userKernel = management.kernel {
            guard FileManager.default.fileExists(atPath: userKernel) else {
                throw ContainerizationError(.notFound, message: "Kernel file not found at path \(userKernel)")
            }
            let p = URL(filePath: userKernel)
            return .init(path: p, platform: s)
        }
        return try await ClientKernel.getDefaultKernel(for: s)
    }

    /// Parses key-value pairs from command line arguments.
    ///
    /// Supports formats like "key=value" and standalone keys (treated as "key=").
    /// - Parameter pairs: Array of strings in "key=value" format
    /// - Returns: Dictionary mapping keys to values
    public static func parseKeyValuePairs(_ pairs: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for pair in pairs {
            let components = pair.split(separator: "=", maxSplits: 1)
            if components.count == 2 {
                result[String(components[0])] = String(components[1])
            } else {
                result[pair] = ""
            }
        }
        return result
    }
}
