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

import ContainerResource
import ContainerXPC
import Containerization
import ContainerizationError
import Foundation

/// Pods: machines that several containers run inside and share.
public struct ClientPod {
    static let serviceIdentifier = "com.apple.container.core.container-core-containers"

    /// Write down a pod, so containers can be placed in it before it boots.
    public static func create(
        configuration: PodConfiguration,
        kernel: Kernel,
        initImage: String? = nil
    ) async throws {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .podCreate)
        message.set(key: .podConfig, value: try JSONEncoder().encode(configuration))
        message.set(key: .kernel, value: try JSONEncoder().encode(kernel))
        if let initImage {
            message.set(key: .initImage, value: initImage)
        }
        _ = try await client.send(message)
    }

    /// Make the sandbox a container is created in.
    ///
    /// The runtime interface has a sandbox created and left ready before
    /// containers are created in it. Here a container joins its pod's machine
    /// before that machine boots, and booting it is what starts the containers
    /// placed in it, so the sandbox is written down here and comes up with its
    /// container rather than ahead of it.
    /// https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto
    public static func run(
        configuration: PodConfiguration,
        kernel: Kernel,
        initImage: String? = nil
    ) async throws {
        try await Self.create(configuration: configuration, kernel: kernel, initImage: initImage)
    }

    /// Boot a pod's machine, with the containers that belong to it inside.
    ///
    /// `dynamicEnv` carries per-boot environment such as the caller's
    /// SSH_AUTH_SOCK to every container the machine starts, the same
    /// donation a container's own start delivers.
    public static func start(_ id: String, dynamicEnv: [String: String] = [:]) async throws {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .podStart)
        message.set(key: .podId, value: id)
        if !dynamicEnv.isEmpty {
            message.set(key: .dynamicEnv, value: try JSONEncoder().encode(dynamicEnv))
        }
        _ = try await client.send(message)
    }

    /// Stop a pod's machine, and with it every container inside.
    public static func stop(_ id: String) async throws {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .podStop)
        message.set(key: .podId, value: id)
        _ = try await client.send(message)
    }

    /// Take a pod away, along with its containers when forced.
    public static func delete(_ id: String, force: Bool = false) async throws {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .podDelete)
        message.set(key: .podId, value: id)
        message.set(key: .forceDelete, value: force)
        _ = try await client.send(message)
    }

    /// Everything known about a pod, including the containers in it.
    public static func inspect(_ id: String) async throws -> PodSnapshot {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .podInspect)
        message.set(key: .podId, value: id)
        let reply = try await client.send(message)

        guard let data = reply.dataNoCopy(key: .podSnapshot) else {
            throw ContainerizationError(.notFound, message: "pod not found: \(id)")
        }
        return try JSONDecoder().decode(PodSnapshot.self, from: data)
    }

    /// Every pod.
    public static func list() async throws -> [PodSnapshot] {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .podList)
        let reply = try await client.send(message)

        guard let data = reply.dataNoCopy(key: .podSnapshots) else {
            return []
        }
        return try JSONDecoder().decode([PodSnapshot].self, from: data)
    }

    /// Hold a running pod to a memory size, which its containers share.
    public static func update(_ id: String, memoryInBytes: UInt64) async throws {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .podUpdate)
        message.set(key: .podId, value: id)
        message.set(key: .memoryInBytes, value: memoryInBytes)
        _ = try await client.send(message)
    }
}
