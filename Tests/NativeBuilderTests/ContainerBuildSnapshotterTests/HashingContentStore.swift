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

import ContainerBuildIR
import ContainerizationOCI
import Crypto
import Foundation

/// Test-local ContentStore that computes real sha256 digests from ingested file contents.
/// - Returns canonical "sha256:<64hex>" strings from completeIngestSession
/// - Stores bytes keyed by canonical digest for later retrieval via get(digest:)
public actor HashingContentStore: ContentStore {
    private var storage: [String: Data] = [:]
    private var sessions: [String: URL] = [:]
    private var nextSessionId: Int = 0
    private let baseDir: URL

    public init(baseDir: URL? = nil) {
        self.baseDir = baseDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("hashing-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: self.baseDir, withIntermediateDirectories: true)
    }

    // MARK: - ContentStore protocol

    public func get(digest: String) async throws -> (any Content)? {
        guard let data = storage[digest] else { return nil }
        return TestContent(data: data)
    }

    public func get<T: Decodable & Sendable>(digest: String) async throws -> T? {
        guard let data = storage[digest] else { return nil }
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    public func put<T: Codable & Sendable>(_ object: T, digest: String) async throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(object)
        storage[digest] = data
    }

    @discardableResult
    public func delete(digests: [String]) async throws -> ([String], UInt64) {
        var deleted: [String] = []
        var total: UInt64 = 0
        for d in digests {
            if let data = storage.removeValue(forKey: d) {
                deleted.append(d)
                total += UInt64(data.count)
            }
        }
        return (deleted, total)
    }

    @discardableResult
    public func delete(keeping: [String]) async throws -> ([String], UInt64) {
        let keep = Set(keeping)
        var deleted: [String] = []
        var total: UInt64 = 0
        for (k, v) in storage where !keep.contains(k) {
            storage.removeValue(forKey: k)
            deleted.append(k)
            total += UInt64(v.count)
        }
        return (deleted, total)
    }

    @discardableResult
    public func ingest(_ body: @Sendable @escaping (URL) async throws -> Void) async throws -> [String] {
        // One-shot ingest helper using a temporary dir
        let dir = baseDir.appendingPathComponent("ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
        // Compute digests for all files and store them
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        var digests: [String] = []
        for f in files {
            let data = try Data(contentsOf: f)
            let d = try ContainerBuildIR.Digest.compute(data, using: .sha256).stringValue
            storage[d] = data
            digests.append(d)
        }
        return digests
    }

    public func newIngestSession() async throws -> (id: String, ingestDir: URL) {
        nextSessionId += 1
        let id = "hs-\(nextSessionId)"
        let dir = baseDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessions[id] = dir
        return (id, dir)
    }

    public func completeIngestSession(_ sessionId: String) async throws -> [String] {
        guard let dir = sessions.removeValue(forKey: sessionId) else {
            throw StoreError.sessionNotFound(sessionId)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        var digests: [String] = []
        if FileManager.default.fileExists(atPath: dir.path) {
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            for file in files {
                let data = try Data(contentsOf: file)
                let d = try ContainerBuildIR.Digest.compute(data, using: .sha256).stringValue
                storage[d] = data
                digests.append(d)
            }
        }
        return digests
    }

    public func cancelIngestSession(_ sessionId: String) async throws {
        if let dir = sessions.removeValue(forKey: sessionId) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Supporting types

    public enum StoreError: LocalizedError {
        case sessionNotFound(String)
        public var errorDescription: String? {
            switch self {
            case .sessionNotFound(let s): return "Ingest session not found: \(s)"
            }
        }
    }

    private struct TestContent: Content {
        let _data: Data
        init(data: Data) { self._data = data }
        var path: URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
        func digest() throws -> SHA256.Digest {
            SHA256.hash(data: _data)
        }
        func size() throws -> UInt64 { UInt64(_data.count) }
        func data() throws -> Data { _data }
        func data(offset: UInt64, length: Int) throws -> Data? {
            let start = Int(offset)
            guard start < _data.count else { return nil }
            let end = min(start + length, _data.count)
            return _data.subdata(in: start..<end)
        }
        func decode<T: Decodable>() throws -> T {
            try JSONDecoder().decode(T.self, from: _data)
        }
    }
}
