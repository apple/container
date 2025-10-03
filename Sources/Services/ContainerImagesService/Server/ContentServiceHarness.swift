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

import ContainerImagesServiceClient
import ContainerXPC
import Containerization
import ContainerizationError
import Foundation
import Logging

public struct ContentServiceHarness: Sendable {
    private let log: Logging.Logger
    private let service: ContentStoreService

    public init(service: ContentStoreService, log: Logging.Logger) {
        self.log = log
        self.service = service
    }

    @Sendable
    public func get(_ message: XPCMessage) async throws -> XPCMessage {
        let d = message.string(key: .digest)
        guard let d else {
            throw ContainerizationError(.invalidArgument, message: "missing digest")
        }
        guard let path = try await service.get(digest: d) else {
            let err = ContainerizationError(.notFound, message: "digest \(d) not found")
            let reply = message.reply()
            reply.set(error: err)
            return reply
        }
        let reply = message.reply()
        reply.set(key: .contentPath, value: path.path(percentEncoded: false))
        return reply
    }

    @Sendable
    public func delete(_ message: XPCMessage) async throws -> XPCMessage {
        let data = message.dataNoCopy(key: .digests)
        guard let data else {
            throw ContainerizationError(.invalidArgument, message: "missing digest")
        }
        let digests = try JSONDecoder().decode([String].self, from: data)
        let (deleted, size) = try await self.service.delete(digests: digests)
        let d = try JSONEncoder().encode(deleted)
        let reply = message.reply()
        reply.set(key: .digests, value: d)
        reply.set(key: .size, value: size)
        return reply
    }

    @Sendable
    public func clean(_ message: XPCMessage) async throws -> XPCMessage {
        let data = message.dataNoCopy(key: .digests)
        guard let data else {
            throw ContainerizationError(.invalidArgument, message: "missing digest")
        }
        let digests = try JSONDecoder().decode([String].self, from: data)
        let (deleted, size) = try await self.service.delete(keeping: digests)
        let d = try JSONEncoder().encode(deleted)
        let reply = message.reply()
        reply.set(key: .digests, value: d)
        reply.set(key: .size, value: size)
        return reply
    }

    @Sendable
    public func newIngestSession(_ message: XPCMessage) async throws -> XPCMessage {
        let session = try await self.service.newIngestSession()
        let id = session.id
        let dir = session.ingestDir
        let reply = message.reply()
        reply.set(key: .directory, value: dir.path(percentEncoded: false))
        reply.set(key: .ingestSessionId, value: id)
        return reply
    }

    @Sendable
    public func cancelIngestSession(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .ingestSessionId)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "missing ingest session id")
        }
        try await self.service.cancelIngestSession(id)
        let reply = message.reply()
        return reply
    }

    @Sendable
    public func completeIngestSession(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .ingestSessionId)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "missing ingest session id")
        }
        let ingested = try await self.service.completeIngestSession(id)
        let d = try JSONEncoder().encode(ingested)
        let reply = message.reply()
        reply.set(key: .digests, value: d)
        return reply
    }
}
