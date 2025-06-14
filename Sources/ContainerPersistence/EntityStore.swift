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

import ContainerizationError
import Foundation
import Logging

let metadataFilename: String = "entity.json"

public protocol EntityStore<T> {
    associatedtype T: Codable & Identifiable<String> & Sendable

    func list() async throws -> [T]
    func create(_ entity: T) async throws
    func retrieve(_ id: String) async throws -> T?
    func update(_ entity: T) async throws
    func upsert(_ entity: T) async throws
    func delete(_ id: String) async throws
}

public actor FilesystemEntityStore<T>: EntityStore where T: Codable & Identifiable<String> & Sendable {
    typealias Index = [String: T]

    private let path: URL
    private let type: String
    private var index: Index
    private let log: Logger
    private let encoder = JSONEncoder()

    public init(path: URL, type: String, log: Logger) throws {
        self.path = path
        self.type = type
        self.log = log
        self.index = try Self.load(path: path, log: log)
    }

    public func list() async throws -> [T] {
        Array(index.values)
    }

    public func create(_ entity: T) async throws {
        let metadataUrl = metadataUrl(entity.id)
        guard !FileManager.default.fileExists(atPath: metadataUrl.path) else {
            throw ContainerizationError(.exists, message: "Entity \(entity.id) already exist")
        }

        try FileManager.default.createDirectory(at: entityUrl(entity.id), withIntermediateDirectories: true)
        let data = try encoder.encode(entity)
        try data.write(to: metadataUrl)
        index[entity.id] = entity
    }

    public func retrieve(_ id: String) throws -> T? {
        index[id]
    }

    public func update(_ entity: T) async throws {
        let metadataUrl: URL = metadataUrl(entity.id)
        guard FileManager.default.fileExists(atPath: metadataUrl.path) else {
            throw ContainerizationError(.notFound, message: "Entity \(entity.id) not found")
        }

        let data = try encoder.encode(entity)
        try data.write(to: metadataUrl)
        index[entity.id] = entity
    }

    public func upsert(_ entity: T) async throws {
        let metadataUrl: URL = metadataUrl(entity.id)
        let data = try encoder.encode(entity)
        try data.write(to: metadataUrl)
        index[entity.id] = entity
    }

    public func delete(_ id: String) async throws {
        let metadataUrl = entityUrl(id)
        guard FileManager.default.fileExists(atPath: metadataUrl.path) else {
            throw ContainerizationError(.notFound, message: "entity \(id) not found")
        }
        try FileManager.default.removeItem(at: metadataUrl)
        index.removeValue(forKey: id)
    }

    public func entityUrl(_ id: String) -> URL {
        path.appendingPathComponent(id)
    }

    private static func load(path: URL, log: Logger) throws -> Index {
        let directories = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
        var index: FilesystemEntityStore<T>.Index = Index()
        let decoder = JSONDecoder()

        for entityUrl in directories {
            do {
                let metadataUrl = entityUrl.appendingPathComponent(metadataFilename)
                let data = try Data(contentsOf: metadataUrl)
                let entity = try decoder.decode(T.self, from: data)
                index[entity.id] = entity
            } catch {
                log.warning(
                    "failed to load entity, ignoring",
                    metadata: [
                        "path": "\(entityUrl)"
                    ])
            }
        }

        return index
    }

    private func metadataUrl(_ id: String) -> URL {
        entityUrl(id).appendingPathComponent(metadataFilename)
    }
}
