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

import ContainerizationError
import ContainerizationOCI
import Foundation

public enum NodeKind: String, Codable, Sendable {
    case linux
}

public struct NodeConfiguration: Codable, Sendable, Equatable {
    public let name: String
    public let kind: NodeKind
    public let roles: [String]

    /// Creates a node configuration.
    ///
    /// - Throws: `.invalidArgument` if `name` is not a valid container name or `roles` is empty.
    public init(name: String, kind: NodeKind = .linux, roles: [String]) throws {
        self.name = name
        self.kind = kind
        self.roles = roles
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case name, kind, roles
    }

    /// Decodes a node configuration, ignoring unknown keys and defaulting absent optional ones.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(NodeKind.self, forKey: .kind) ?? .linux
        roles = try container.decode([String].self, forKey: .roles)
        try validate()
    }

    private func validate() throws {
        guard ManagedContainer.nameValid(name) else {
            throw ContainerizationError(.invalidArgument, message: "node name \(name) is not a valid container name")
        }
        guard !roles.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "node \(name) must have at least one role")
        }
    }
}

/// What the user asked for when creating a cluster. Persisted at create time.
public struct ClusterConfiguration: Codable, Sendable, Equatable, Identifiable {
    /// The most worker nodes a cluster may have.
    public static let maxWorkers: UInt = 1024

    public let name: String
    public var id: String { name }
    public let kubernetesVersion: String
    public let cni: String?
    public let fqdn: String?
    /// Whether node containers are removed when they stop (`--rm`).
    public let remove: Bool
    /// Whether nodes use the host's image store (`--shared-image-store`).
    public let sharedImageStore: Bool
    public let nodes: [NodeConfiguration]
    public let creationDate: Date
    public let labels: ResourceLabels

    /// Creates a cluster configuration.
    ///
    /// - Throws: `.invalidArgument` if the name, Kubernetes version or nodes are invalid.
    public init(
        name: String, kubernetesVersion: String, cni: String? = nil, fqdn: String? = nil,
        remove: Bool = false, sharedImageStore: Bool = false, nodes: [NodeConfiguration], creationDate: Date = Date(), labels: ResourceLabels = .init()
    ) throws {
        self.name = name
        self.kubernetesVersion = kubernetesVersion
        self.cni = cni
        self.fqdn = fqdn
        self.remove = remove
        self.sharedImageStore = sharedImageStore
        self.nodes = nodes
        self.creationDate = creationDate
        self.labels = labels
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case name, kubernetesVersion, cni, fqdn, remove, sharedImageStore, nodes, creationDate, labels
    }

    /// Decodes a cluster configuration, ignoring unknown keys and defaulting absent optional ones
    /// so that the stored format can grow without invalidating existing records.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kubernetesVersion = try container.decode(String.self, forKey: .kubernetesVersion)
        cni = try container.decodeIfPresent(String.self, forKey: .cni)
        fqdn = try container.decodeIfPresent(String.self, forKey: .fqdn)
        remove = try container.decodeIfPresent(Bool.self, forKey: .remove) ?? false
        sharedImageStore = try container.decodeIfPresent(Bool.self, forKey: .sharedImageStore) ?? false
        nodes = try container.decode([NodeConfiguration].self, forKey: .nodes)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate) ?? Date(timeIntervalSince1970: 0)
        labels = try container.decodeIfPresent(ResourceLabels.self, forKey: .labels) ?? ResourceLabels()
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kubernetesVersion, forKey: .kubernetesVersion)
        // Explicit null when absent (JSON/YAML); TOML omits nil values but throws on Optional encode.
        if let cni { try c.encode(cni, forKey: .cni) } else { try c.encodeNil(forKey: .cni) }
        if let fqdn { try c.encode(fqdn, forKey: .fqdn) } else { try c.encodeNil(forKey: .fqdn) }
        try c.encode(remove, forKey: .remove)
        try c.encode(sharedImageStore, forKey: .sharedImageStore)
        try c.encode(nodes, forKey: .nodes)
        try c.encode(creationDate, forKey: .creationDate)
        try c.encode(labels, forKey: .labels)
    }

    /// Whether `version` is a valid image tag. Defers to ContainerizationOCI's tag grammar, whose pattern isn't public:
    /// `Reference.withTag` applies it to the whole string, and comparing the result rejects the extra
    /// forms it tolerates (a leading `:` or a trailing `@digest`).
    static func kubernetesVersionValid(_ version: String) -> Bool {
        guard let reference = try? Reference.parse("kindest/node").withTag(version) else { return false }
        return reference.tag == version
    }

    private func validate() throws {
        guard ClusterResource.nameValid(name) else {
            throw ContainerizationError(.invalidArgument, message: "cluster name \(name) is not valid")
        }
        guard Self.kubernetesVersionValid(kubernetesVersion) else {
            throw ContainerizationError(
                .invalidArgument, message: "cluster \(name) has an invalid Kubernetes version \(kubernetesVersion)")
        }
        // One control-plane node plus at most `maxWorkers` workers.
        guard (1...Int(Self.maxWorkers) + 1).contains(nodes.count) else {
            throw ContainerizationError(
                .invalidArgument, message: "cluster \(name) must have between 1 and \(Self.maxWorkers + 1) nodes, got \(nodes.count)")
        }
        guard Set(nodes.map(\.name)).count == nodes.count else {
            throw ContainerizationError(.invalidArgument, message: "cluster \(name) has duplicate node names")
        }
    }

    public static let controlPlaneRole = "control-plane"
    public static let workerRole = "worker"

    /// Container name of the `index`th (1-based) worker of `cluster`.
    public static func workerName(cluster: String, index: Int) -> String {
        "\(workerNamePrefix(cluster: cluster))\(index)"
    }

    public static func workerNamePrefix(cluster: String) -> String {
        "\(cluster)-worker-"
    }

    /// The Kubernetes version carried by the node image's tag, e.g. `v1.35.5`.
    public static func kubernetesVersion(nodeImage: String) throws -> String {
        let nameAndTag = nodeImage.split(separator: "@").first.map(String.init) ?? nodeImage
        guard let ref = try? Reference.parse(nameAndTag), let tag = ref.tag else {
            throw ContainerizationError(
                .invalidArgument,
                message: "node image \(nodeImage) has no tag; use a tagged image such as docker.io/kindest/node:v1.34.11")
        }
        return tag
    }

    /// Builds the configuration for `container cluster create`. With no workers the
    /// single node carries both roles; otherwise workers are `<name>-worker-<n>`.
    public static func make(
        name: String, nodeImage: String, remove: Bool, sharedImageStore: Bool = false,
        workers: UInt, cni: String?, fqdn: String?
    ) throws -> ClusterConfiguration {
        guard workers <= maxWorkers else {
            throw ContainerizationError(.invalidArgument, message: "a cluster may have at most \(maxWorkers) workers, got \(workers)")
        }
        let version = try kubernetesVersion(nodeImage: nodeImage)
        var nodes = [
            try NodeConfiguration(
                name: name,
                roles: workers == 0 ? [controlPlaneRole, workerRole] : [controlPlaneRole])
        ]
        for i in 0..<Int(workers) {
            nodes.append(try NodeConfiguration(name: workerName(cluster: name, index: i + 1), roles: [workerRole]))
        }
        return try ClusterConfiguration(name: name, kubernetesVersion: version, cni: cni, fqdn: fqdn, remove: remove, sharedImageStore: sharedImageStore, nodes: nodes)
    }
}
