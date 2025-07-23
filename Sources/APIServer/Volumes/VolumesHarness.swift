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

struct VolumesHarness: Sendable {
    let log: Logging.Logger
    let service: VolumesService

    init(service: VolumesService, log: Logging.Logger) {
        self.log = log
        self.service = service
    }

    @Sendable
    func list(_ message: XPCMessage) async throws -> XPCMessage {
        let response = try await service.list()
        let data = try JSONEncoder().encode(response)

        let reply = message.reply()
        reply.set(key: .volumeListResponse, value: data)
        return reply
    }

    @Sendable
    func create(_ message: XPCMessage) async throws -> XPCMessage {
        let data = message.dataNoCopy(key: .volumeCreateRequest)
        guard let data else {
            throw ContainerizationError(.invalidArgument, message: "volume create request cannot be empty")
        }

        let request = try JSONDecoder().decode(VolumeCreateRequest.self, from: data)
        let volume = try await service.create(request)
        let responseData = try JSONEncoder().encode(volume)

        let reply = message.reply()
        reply.set(key: .volume, value: responseData)
        return reply
    }

    @Sendable
    func delete(_ message: XPCMessage) async throws -> XPCMessage {
        let data = message.dataNoCopy(key: .volumeDeleteRequest)
        guard let data else {
            throw ContainerizationError(.invalidArgument, message: "volume delete request cannot be empty")
        }

        let request = try JSONDecoder().decode(VolumeDeleteRequest.self, from: data)
        try await service.delete(request)

        return message.reply()
    }

    @Sendable
    func inspect(_ message: XPCMessage) async throws -> XPCMessage {
        let name = message.string(key: .volumeName)
        guard let name else {
            throw ContainerizationError(.invalidArgument, message: "volume name cannot be empty")
        }

        let response = try await service.inspect(name)
        let data = try JSONEncoder().encode(response)

        let reply = message.reply()
        reply.set(key: .volumeInspectResponse, value: data)
        return reply
    }
}
