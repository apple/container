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

import ContainerClusterServiceClient
import ContainerResource
import ContainerizationError
import Foundation
import Logging

/// Persists each cluster's `ClusterConfiguration` at `<root>/<name>/cluster.json`.
public struct ClusterStore: Sendable {
    public static let fileName = "cluster.json"
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private func directory(for name: String) throws -> URL {
        guard ClusterResource.nameValid(name) else {
            throw ContainerizationError(.invalidArgument, message: "invalid cluster name \(name)")
        }
        return root.appending(path: name, directoryHint: .isDirectory)
    }

    private func file(for name: String) throws -> URL {
        try directory(for: name).appending(path: Self.fileName)
    }

    public func save(_ configuration: ClusterConfiguration) throws {
        // On a case-insensitive filesystem `DEV` and `dev` share a directory; refuse to clobber a differently-cased record.
        if let stored = try? readRecord(name: configuration.name), stored.name != configuration.name {
            throw ContainerizationError(
                .exists, message: "cluster \(configuration.name) conflicts with existing cluster \(stored.name)")
        }
        try FileManager.default.createDirectory(at: try directory(for: configuration.name), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(configuration).write(to: try file(for: configuration.name), options: .atomic)
    }

    private func readRecord(name: String) throws -> ClusterConfiguration? {
        let url = try file(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ClusterConfiguration.self, from: Data(contentsOf: url))
    }

    /// Returns nil when the stored record's name differs from `name` (case-insensitive filesystem alias).
    public func load(name: String) throws -> ClusterConfiguration? {
        guard let record = try readRecord(name: name), record.name == name else { return nil }
        return record
    }

    public func loadAll(log: Logger) -> [ClusterConfiguration] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { entry in
            let name = entry.lastPathComponent
            guard ClusterResource.nameValid(name) else { return nil }
            do {
                return try load(name: name)
            } catch {
                log.warning("skipping unreadable cluster configuration", metadata: ["name": "\(name)", "error": "\(error)"])
                return nil
            }
        }
    }

    public func remove(name: String) throws {
        let dir = try directory(for: name)
        // The root also holds unrelated entries (e.g. `port.lock`); only remove a cluster directory.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue,
            FileManager.default.fileExists(atPath: dir.appending(path: Self.fileName).path)
        else { return }
        // Don't remove a differently-cased record that aliases this directory.
        if let stored = try? readRecord(name: name), stored.name != name { return }
        try FileManager.default.removeItem(at: dir)
    }
}
