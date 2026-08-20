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

import ContainerizationOCI
import Foundation

/// The configuration of a pod.
///
/// The shape follows the runtime interface's `PodSandboxConfig`.
/// https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto
public struct PodConfiguration: Sendable, Codable {
    /// Identifier for the pod.
    public var id: String

    /// Mint ids the way containers mint theirs, a lowercased UUID.
    ///
    /// A pod is a lifetime rather than a description of what it holds, so it
    /// is told apart by the id it is given. Two pods may hold containers from
    /// the same image, and a pod named after a container it holds would claim
    /// the runtime service that container claims.
    public static func generateId() -> String { UUID().uuidString.lowercased() }

    /// The runtime that runs the pod's machine.
    ///
    /// A pod is one machine, so its containers run under one runtime, and it
    /// is the pod that names it. A container placed in a pod asking for a
    /// different one is asking for a machine this pod is not.
    public var runtimeHandler: String = "container-runtime-linux"

    /// Resources like cpu, memory and swap. A container may hold its own
    /// limit within these; left alone it draws on the whole pool.
    public var resources: ContainerConfiguration.Resources = .init()

    /// The hostname for the pod.
    public var hostname: String?

    /// The DNS configuration for the pod.
    public var dns: ContainerConfiguration.DNSConfiguration?

    /// Kernel parameters for the pod. Its containers share one kernel, so none
    /// of them can set one for itself alone.
    public var sysctls: [String: String] = [:]

    /// The networks the pod attaches to.
    public var networks: [AttachmentConfiguration] = []

    /// Ports published to the host.
    public var publishedPorts: [PublishPort] = []

    /// Whether the pod's containers see each other's processes.
    public var shareProcessNamespace: Bool = false

    /// Enable nested virtualization support.
    public var virtualization: Bool = false

    /// Enable Rosetta.
    public var rosetta: Bool = false

    /// Key-value properties for the pod.
    public var labels: [String: String] = [:]

    /// Configured platform for the pod.
    public var platform: ContainerizationOCI.Platform = .current

    /// The init image the pod's machine boots.
    ///
    /// A pod clones the image's filesystem when it is made and boots that
    /// clone for as long as it lives, so the image it was made from is the
    /// only account of which agent its containers talk to. A caller comparing
    /// this against the init image the runtime is configured with is asking
    /// whether the machine still matches the plane driving it.
    public var initImage: ImageDescription?

    /// The time at which the pod was created.
    public var creationDate: Date = Date()

    public init(id: String) {
        self.id = id
    }

    /// The sandbox a container asks for when it names no pod of its own.
    ///
    /// The runtime interface has the caller create a sandbox and then create
    /// containers in it, so a container that came without one has a sandbox
    /// made for it first, out of the fields that are the sandbox's to hold.
    /// https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto
    public init(sandboxFor container: ContainerConfiguration) {
        self.init(id: container.pod)
        runtimeHandler = container.runtimeHandler
        resources = container.resources
        dns = container.dns
        networks = container.networks
        publishedPorts = container.publishedPorts
        virtualization = container.virtualization
        rosetta = container.rosetta
        platform = container.platform
        labels = container.labels
        // Nobody named this pod. It carries a name of its own because the
        // container needed a machine to run in and was given one, which is what
        // a volume mounted without a name is.
        labels[Self.anonymousLabel] = ""
    }

    /// Read a pod written by any version of this service.
    ///
    /// A pod outlives the process that wrote it, so a field this type gains is
    /// a field the pods already on disk do not carry. The compiler's own
    /// decoding asks for every key and fails on the first one missing, which
    /// would make every pod written before the field unreadable, and a pod
    /// that cannot be read is a pod that is not there: the service skips it,
    /// and the container it holds is told its pod does not exist. Each field
    /// that has a default is taken as absent-means-default, which is how the
    /// container configuration reads its own.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        runtimeHandler = try values.decodeIfPresent(String.self, forKey: .runtimeHandler) ?? "container-runtime-linux"
        resources = try values.decodeIfPresent(ContainerConfiguration.Resources.self, forKey: .resources) ?? .init()
        hostname = try values.decodeIfPresent(String.self, forKey: .hostname)
        dns = try values.decodeIfPresent(ContainerConfiguration.DNSConfiguration.self, forKey: .dns)
        sysctls = try values.decodeIfPresent([String: String].self, forKey: .sysctls) ?? [:]
        networks = try values.decodeIfPresent([AttachmentConfiguration].self, forKey: .networks) ?? []
        publishedPorts = try values.decodeIfPresent([PublishPort].self, forKey: .publishedPorts) ?? []
        shareProcessNamespace = try values.decodeIfPresent(Bool.self, forKey: .shareProcessNamespace) ?? false
        virtualization = try values.decodeIfPresent(Bool.self, forKey: .virtualization) ?? false
        rosetta = try values.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
        labels = try values.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        platform = try values.decodeIfPresent(ContainerizationOCI.Platform.self, forKey: .platform) ?? .current
        creationDate = try values.decodeIfPresent(Date.self, forKey: .creationDate) ?? Date()
    }
}

/// The runtime state of a pod.
public enum PodState: String, Sendable, Codable {
    case ready
    case notReady
}

extension PodConfiguration {
    /// Reserved label key for marking anonymous pods
    public static let anonymousLabel = "com.apple.container.resource.anonymous"

    /// Whether this is an anonymous pod (detected via label)
    public var isAnonymous: Bool {
        labels[Self.anonymousLabel] != nil
    }
}
