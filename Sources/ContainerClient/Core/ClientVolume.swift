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

import ContainerXPC
import Containerization
import Foundation

public struct ClientVolume {
    static let serviceIdentifier = "com.apple.container.apiserver"

    public static func create(_ request: VolumeCreateRequest) async throws -> Volume {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .volumeCreate)
        let data = try JSONEncoder().encode(request)
        message.set(key: .volumeCreateRequest, value: data)

        let reply = try await client.send(message)

        guard let responseData = reply.dataNoCopy(key: .volume) else {
            throw VolumeError.storageError("Invalid response from server")
        }

        return try JSONDecoder().decode(Volume.self, from: responseData)
    }

    public static func delete(_ request: VolumeDeleteRequest) async throws {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .volumeDelete)
        let data = try JSONEncoder().encode(request)
        message.set(key: .volumeDeleteRequest, value: data)

        _ = try await client.send(message)
    }

    public static func list() async throws -> VolumeListResponse {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .volumeList)
        let reply = try await client.send(message)

        guard let responseData = reply.dataNoCopy(key: .volumeListResponse) else {
            throw VolumeError.storageError("Invalid response from server")
        }

        return try JSONDecoder().decode(VolumeListResponse.self, from: responseData)
    }

    public static func inspect(_ name: String) async throws -> VolumeInspectResponse {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .volumeInspect)
        message.set(key: .volumeName, value: name)

        let reply = try await client.send(message)

        guard let responseData = reply.dataNoCopy(key: .volumeInspectResponse) else {
            throw VolumeError.storageError("Invalid response from server")
        }

        return try JSONDecoder().decode(VolumeInspectResponse.self, from: responseData)
    }
}
