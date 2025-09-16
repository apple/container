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

import ContainerClient
import ContainerXPC
import ContainerizationError
import Foundation
import Logging

public struct VolumesHarness: Sendable {
    let log: Logging.Logger
    let service: VolumesService

    public init(service: VolumesService, log: Logging.Logger) {
        self.log = log
        self.service = service
    }

    @Sendable
    public func list(_ message: XPCMessage) async throws -> XPCMessage {
        let volumes = try await service.list()
        let data = try JSONEncoder().encode(volumes)

        let reply = message.reply()
        reply.set(key: .volumes, value: data)
        return reply
    }

    @Sendable
    public func create(_ message: XPCMessage) async throws -> XPCMessage {
        guard let name = message.string(key: .volumeName) else {
            throw ContainerizationError(.invalidArgument, message: "volume name cannot be empty")
        }

        let driver = message.string(key: .volumeDriver) ?? "local"

        let driverOpts: [String: String]
        if let driverOptsData = message.dataNoCopy(key: .volumeDriverOpts) {
            driverOpts = try JSONDecoder().decode([String: String].self, from: driverOptsData)
        } else {
            driverOpts = [:]
        }

        let labels: [String: String]
        if let labelsData = message.dataNoCopy(key: .volumeLabels) {
            labels = try JSONDecoder().decode([String: String].self, from: labelsData)
        } else {
            labels = [:]
        }

        let volume = try await service.create(name: name, driver: driver, driverOpts: driverOpts, labels: labels)
        let responseData = try JSONEncoder().encode(volume)

        let reply = message.reply()
        reply.set(key: .volume, value: responseData)
        return reply
    }

    @Sendable
    public func delete(_ message: XPCMessage) async throws -> XPCMessage {
        guard let name = message.string(key: .volumeName) else {
            throw ContainerizationError(.invalidArgument, message: "volume name cannot be empty")
        }

        try await service.delete(name: name)
        return message.reply()
    }

    @Sendable
    public func inspect(_ message: XPCMessage) async throws -> XPCMessage {
        guard let name = message.string(key: .volumeName) else {
            throw ContainerizationError(.invalidArgument, message: "volume name cannot be empty")
        }

        let volume = try await service.inspect(name)
        let data = try JSONEncoder().encode(volume)

        let reply = message.reply()
        reply.set(key: .volume, value: data)
        return reply
    }
}
