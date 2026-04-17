//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import Containerization
import ContainerizationOCI
import Foundation
import Logging

public actor ContentStoreService {
    private let log: Logger
    private let contentStore: LocalContentStore
    private let root: URL

    public init(root: URL, log: Logger) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.appendingPathComponent("content")
        self.contentStore = try LocalContentStore(path: self.root)
        self.log = log
    }

    public func get(digest: String) async throws -> URL? {
        self.log.trace(
            "ContentStoreService: enter",
            metadata: [
                "func": "\(#function)",
                "digest": "\(digest)",
            ]
        )
        defer {
            self.log.trace(
                "ContentStoreService: exit",
                metadata: [
                    "func": "\(#function)",
                    "digest": "\(digest)",
                ]
            )
        }

        return try await self.contentStore.get(digest: digest)?.path
    }

    @discardableResult
    public func delete(digests: [String]) async throws -> ([String], UInt64) {
        self.log.trace(
            "ContentStoreService: enter",
            metadata: [
                "func": "\(#function)",
                "digests": "\(digests)",
            ]
        )
        defer {
            self.log.trace(
                "ContentStoreService: exit",
                metadata: [
                    "func": "\(#function)",
                    "digests": "\(digests)",
                ]
            )
        }

        return try await self.contentStore.delete(digests: digests)
    }

    @discardableResult
    public func delete(keeping: [String]) async throws -> ([String], UInt64) {
        self.log.debug(
            "ContentStoreService: enter",
            metadata: [
                "func": "\(#function)",
                "keeping": "\(keeping)",
            ]
        )
        defer {
            self.log.debug(
                "ContentStoreService: exit",
                metadata: [
                    "func": "\(#function)",
                    "keeping": "\(keeping)",
                ]
            )
        }

        return try await self.contentStore.delete(keeping: keeping)
    }

    public func newIngestSession() async throws -> (id: String, ingestDir: URL) {
        self.log.debug(
            "ContentStoreService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            self.log.debug(
                "ContentStoreService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }
        return try await self.contentStore.newIngestSession()
    }

    public func completeIngestSession(_ id: String) async throws -> [String] {
        self.log.debug(
            "ContentStoreService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            self.log.debug(
                "ContentStoreService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        return try await self.contentStore.completeIngestSession(id)
    }

    public func cancelIngestSession(_ id: String) async throws {
        self.log.debug(
            "ContentStoreService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            self.log.debug(
                "ContentStoreService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        return try await self.contentStore.cancelIngestSession(id)
    }
}
