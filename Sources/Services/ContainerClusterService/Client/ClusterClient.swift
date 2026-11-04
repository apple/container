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

#if os(macOS)
import ContainerResource
import ContainerXPC
import ContainerizationError
import Foundation

/// Client for the `container-core-clusters` XPC service.
public struct ClusterClient: Sendable {
    public static let serviceIdentifier = "com.apple.container.core.container-core-clusters"

    private let xpcClient: XPCClient

    public init() {
        self.xpcClient = XPCClient(service: Self.serviceIdentifier)
    }

    @discardableResult
    private func send(_ message: XPCMessage) async throws -> XPCMessage {
        do {
            return try await xpcClient.send(message, responseTimeout: .seconds(30))
        } catch let error as ContainerizationError where error.code == .interrupted {
            throw ContainerizationError(
                .interrupted,
                message:
                    "cluster service unavailable (\(error.message)); make sure the system is running ('container system start') and restart it after upgrading"
            )
        }
    }

    /// Records a new cluster and returns it. Throws `.exists` if a live cluster with that name is already recorded.
    public func create(configuration: ClusterConfiguration) async throws -> ClusterResource {
        let request = XPCMessage(route: .clusterCreate)
        request.set(key: .configuration, value: try JSONEncoder().encode(configuration))
        let reply = try await send(request)
        guard let data = reply.dataNoCopy(key: .cluster) else {
            throw ContainerizationError(.internalError, message: "missing cluster in reply")
        }
        return try JSONDecoder().decode(ClusterResource.self, from: data)
    }

    /// Throws `.notFound` if no cluster with that name is recorded.
    public func get(name: String) async throws -> ClusterResource {
        let request = XPCMessage(route: .clusterGet)
        request.set(key: .name, value: name)
        let reply = try await send(request)
        guard let data = reply.dataNoCopy(key: .cluster) else {
            throw ContainerizationError(.internalError, message: "missing cluster in reply")
        }
        return try JSONDecoder().decode(ClusterResource.self, from: data)
    }

    public func list() async throws -> [ClusterResource] {
        let reply = try await send(XPCMessage(route: .clusterList))
        guard let data = reply.dataNoCopy(key: .clusters) else {
            throw ContainerizationError(.internalError, message: "missing clusters in reply")
        }
        return try JSONDecoder().decode([ClusterResource].self, from: data)
    }

    /// Removes the cluster record. Throws `.notFound` if no cluster with that name is recorded.
    public func delete(name: String) async throws {
        let request = XPCMessage(route: .clusterDelete)
        request.set(key: .name, value: name)
        try await send(request)
    }
}
#endif
