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

import ContainerizationError
import Foundation
import Logging
import SystemPackage

private let metadataFilename: String = "entity.json"

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

    private let path: FilePath
    private let type: String
    private var index: Index
    private let log: Logger
    private let encoder = JSONEncoder()

    public init(path: FilePath, type: String, log: Logger) throws {
        self.path = path
        self.type = type
        self.log = log
        self.index = try Self.load(path: path, log: log)
    }

    public func list() async throws -> [T] {
        Array(index.values)
    }

    public func create(_ entity: T) async throws {
        let metadataPath = try metadataPath(entity.id)
        guard !FileManager.default.fileExists(atPath: metadataPath.string) else {
            throw ContainerizationError(.exists, message: "entity \(entity.id) already exist")
        }

        let entityPath = try entityPath(entity.id)
        try FileManager.default.createDirectory(atPath: entityPath.string, withIntermediateDirectories: true)
        let data = try encoder.encode(entity)
        try data.write(to: URL(filePath: metadataPath.string))
        index[entity.id] = entity
    }

    public func retrieve(_ id: String) throws -> T? {
        index[id]
    }

    public func update(_ entity: T) async throws {
        let metadataPath = try metadataPath(entity.id)
        guard FileManager.default.fileExists(atPath: metadataPath.string) else {
            throw ContainerizationError(.notFound, message: "entity \(entity.id) not found")
        }

        let data = try encoder.encode(entity)
        try data.write(to: URL(filePath: metadataPath.string))
        index[entity.id] = entity
    }

    public func upsert(_ entity: T) async throws {
        let entityPath = try entityPath(entity.id)
        try FileManager.default.createDirectory(atPath: entityPath.string, withIntermediateDirectories: true)
        let metadataPath = try metadataPath(entity.id)
        let data = try encoder.encode(entity)
        try data.write(to: URL(filePath: metadataPath.string))
        index[entity.id] = entity
    }

    public func delete(_ id: String) async throws {
        let metadataPath = try entityPath(id)
        guard FileManager.default.fileExists(atPath: metadataPath.string) else {
            throw ContainerizationError(.notFound, message: "entity \(id) not found")
        }
        try FileManager.default.removeItem(atPath: metadataPath.string)
        index.removeValue(forKey: id)
    }

    public nonisolated func entityPath(_ id: String) throws -> FilePath {
        guard let component = FilePath.Component(id) else {
            throw ContainerizationError(.invalidArgument, message: "entity ID \(id) cannot be a path component")
        }
        return path.appending(component)
    }

    private static func load(path: FilePath, log: Logger) throws -> Index {
        let directories = try FileManager.default.contentsOfDirectory(atPath: path.string)
        var index: FilesystemEntityStore<T>.Index = Index()
        let decoder = JSONDecoder()

        for filename in directories {
            let metadataPath = path.appending(filename).appending(metadataFilename)
            do {
                let data = try Data(contentsOf: URL(filePath: metadataPath.string))
                let entity = try decoder.decode(T.self, from: data)
                index[entity.id] = entity
            } catch {
                log.warning(
                    "failed to load entity, ignoring",
                    metadata: [
                        "path": "\(metadataPath.string)"
                    ])
            }
        }

        return index
    }

    private func metadataPath(_ id: String) throws -> FilePath {
        try entityPath(id).appending(metadataFilename)
    }
}
