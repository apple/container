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

import ContainerXPC
import Containerization
import Foundation

public struct ClientVolume {
    static let serviceIdentifier = "com.apple.container.apiserver"

    public static func create(
        name: String,
        driver: String = "local",
        driverOpts: [String: String] = [:],
        labels: [String: String] = [:]
    ) async throws -> Volume {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .volumeCreate)
        message.set(key: .volumeName, value: name)
        message.set(key: .volumeDriver, value: driver)

        let driverOptsData = try JSONEncoder().encode(driverOpts)
        message.set(key: .volumeDriverOpts, value: driverOptsData)

        let labelsData = try JSONEncoder().encode(labels)
        message.set(key: .volumeLabels, value: labelsData)

        let reply = try await client.send(message)

        guard let responseData = reply.dataNoCopy(key: .volume) else {
            throw VolumeError.storageError("Invalid response from server")
        }

        return try JSONDecoder().decode(Volume.self, from: responseData)
    }

    public static func delete(name: String) async throws {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .volumeDelete)
        message.set(key: .volumeName, value: name)

        _ = try await client.send(message)
    }

    public static func list() async throws -> [Volume] {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .volumeList)
        let reply = try await client.send(message)

        guard let responseData = reply.dataNoCopy(key: .volumes) else {
            return []
        }

        return try JSONDecoder().decode([Volume].self, from: responseData)
    }

    public static func inspect(_ name: String) async throws -> Volume {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .volumeInspect)
        message.set(key: .volumeName, value: name)

        let reply = try await client.send(message)

        guard let responseData = reply.dataNoCopy(key: .volume) else {
            throw VolumeError.volumeNotFound(name)
        }

        return try JSONDecoder().decode(Volume.self, from: responseData)
    }

}
