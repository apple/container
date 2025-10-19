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

#if os(macOS)
import Crypto
import ContainerizationError
import Foundation
import ContainerizationOCI
import ContainerXPC

public struct RemoteContentStoreClient: ContentStore {
    private static let serviceIdentifier = "com.apple.container.core.container-core-images"
    private static let encoder = JSONEncoder()

    private static func newClient() -> XPCClient {
        XPCClient(service: serviceIdentifier)
    }

    public init() {}

    private func _get(digest: String) async throws -> URL? {
        let client = Self.newClient()
        let request = XPCMessage(route: .contentGet)
        request.set(key: .digest, value: digest)
        do {
            let response = try await client.send(request)
            guard let path = response.string(key: .contentPath) else {
                return nil
            }
            return URL(filePath: path)
        } catch let error as ContainerizationError {
            if error.code == .notFound {
                return nil
            }
            throw error
        }
    }

    public func get(digest: String) async throws -> Content? {
        guard let url = try await self._get(digest: digest) else {
            return nil
        }
        return try LocalContent(path: url)
    }

    public func get<T: Decodable>(digest: String) async throws -> T? {
        guard let content: Content = try await self.get(digest: digest) else {
            return nil
        }
        return try content.decode()
    }

    public func delete(keeping: [String]) async throws -> ([String], UInt64) {
        let client = Self.newClient()
        let request = XPCMessage(route: .contentClean)

        let d = try Self.encoder.encode(keeping)
        request.set(key: .digests, value: d)
        let response = try await client.send(request)

        guard let data = response.dataNoCopy(key: .digests) else {
            throw ContainerizationError.init(.internalError, message: "failed to delete digests")
        }

        let decoder = JSONDecoder()
        let deleted = try decoder.decode([String].self, from: data)
        let size = response.uint64(key: .size)
        return (deleted, size)
    }

    @discardableResult
    public func delete(digests: [String]) async throws -> ([String], UInt64) {
        let client = Self.newClient()
        let request = XPCMessage(route: .contentDelete)

        let d = try Self.encoder.encode(digests)
        request.set(key: .digests, value: d)
        let response = try await client.send(request)

        guard let data = response.dataNoCopy(key: .digests) else {
            throw ContainerizationError.init(.internalError, message: "failed to delete digests")
        }

        let decoder = JSONDecoder()
        let deleted = try decoder.decode([String].self, from: data)
        let size = response.uint64(key: .size)
        return (deleted, size)
    }

    @discardableResult
    public func ingest(_ body: @Sendable @escaping (URL) async throws -> Void) async throws -> [String] {
        let (id, tempPath) = try await self.newIngestSession()
        try await body(tempPath)
        return try await self.completeIngestSession(id)
    }

    public func newIngestSession() async throws -> (id: String, ingestDir: URL) {
        let client = Self.newClient()
        let request = XPCMessage(route: .contentIngestStart)
        let response = try await client.send(request)
        guard let id = response.string(key: .ingestSessionId) else {
            throw ContainerizationError.init(.internalError, message: "failed create new ingest session")
        }
        guard let dir = response.string(key: .directory) else {
            throw ContainerizationError.init(.internalError, message: "failed create new ingest session")
        }
        return (id, URL(filePath: dir))
    }

    @discardableResult
    public func completeIngestSession(_ id: String) async throws -> [String] {
        let client = Self.newClient()
        let request = XPCMessage(route: .contentIngestComplete)

        request.set(key: .ingestSessionId, value: id)

        let response = try await client.send(request)
        guard let data = response.dataNoCopy(key: .digests) else {
            throw ContainerizationError.init(.internalError, message: "failed to delete digests")
        }

        let decoder = JSONDecoder()
        let ingested = try decoder.decode([String].self, from: data)
        return ingested
    }

    public func cancelIngestSession(_ id: String) async throws {
        let client = Self.newClient()
        let request = XPCMessage(route: .contentIngestCancel)
        request.set(key: .ingestSessionId, value: id)
        try await client.send(request)
    }
}

#endif
