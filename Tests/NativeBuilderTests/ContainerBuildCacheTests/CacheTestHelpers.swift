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
import ContainerBuildSnapshotter
import ContainerizationOCI
import Crypto
import Foundation
import Testing

@testable import ContainerBuildCache

// MARK: - Missing Type Definitions for Testing

/// ContentWriter mock for testing
public struct ContentWriter {
    public let ingestDir: URL

    public init(for ingestDir: URL) throws {
        self.ingestDir = ingestDir
    }

    public func write(_ data: Data) throws -> (Int64, SHA256.Digest) {
        let digest = SHA256.hash(data: data)
        // Use the digest string without the sha256: prefix for the filename
        let digestString = digest.map { String(format: "%02x", $0) }.joined()
        let filePath = ingestDir.appendingPathComponent(digestString)
        try data.write(to: filePath)
        return (Int64(data.count), digest)
    }

    public func create(from manifest: CacheManifest) throws -> (Int64, SHA256.Digest) {
        let data = try JSONEncoder().encode(manifest)
        return try write(data)
    }
}

extension Data {
    var sha256: String {
        let digest = (try? ContainerBuildIR.Digest.compute(self, using: .sha256)) ?? (try! ContainerBuildIR.Digest(algorithm: .sha256, bytes: Data(count: 32)))
        return digest.stringValue.replacingOccurrences(of: "sha256:", with: "")
    }
}

// MARK: - Test Environment

/// Test environment with common setup and utilities for cache tests
public struct CacheTestEnvironment {
    public let tempDir: URL

    public init() throws {
        self.tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}

/// Convenience function to create and manage test environment
public func withCacheTestEnvironment<T>(
    _ operation: (CacheTestEnvironment) async throws -> T
) async throws -> T {
    let environment = try CacheTestEnvironment()
    defer { environment.cleanup() }
    return try await operation(environment)
}

// MARK: - Compatibility Layer

/// Compatibility base class for existing XCTest-based tests during migration
/// This maintains the same interface as the original CacheTestCase for gradual migration
open class CacheTestCase {
    public var tempDir: URL!

    public init() {}

    open func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    open func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }
}

// MARK: - ContentStore Protocol
// Using the real ContentStore from ContainerizationOCI

// MARK: - Mock Content

/// Mock Content implementation for testing
public struct MockContent: Content {
    public let path: URL
    private let _data: Data

    public init(data: Data) {
        self._data = data
        self.path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    public func digest() throws -> SHA256.Digest {
        SHA256.hash(data: _data)
    }

    public func size() throws -> UInt64 {
        UInt64(_data.count)
    }

    public func data() throws -> Data {
        _data
    }

    public func data(offset: UInt64, length: Int) throws -> Data? {
        let start = Int(offset)
        let end = min(start + length, _data.count)
        guard start < _data.count else { return nil }
        return _data.subdata(in: start..<end)
    }

    public func decode<T: Decodable>() throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: _data)
    }
}

// MARK: - Mock ContentStore

/// Mock ContentStore for testing cache implementations
public actor MockContentStore: ContentStore {
    private var storage: [String: Data] = [:]
    private var manifests: [String: CacheManifest] = [:]
    private var sessions: [String: URL] = [:]
    private var nextSessionId = 0
    private let baseDir: URL

    public init(baseDir: URL? = nil) {
        self.baseDir = baseDir ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: self.baseDir, withIntermediateDirectories: true)
    }

    // MARK: - ContentStore Interface

    // MARK: - ContentStore Protocol Implementation

    public func get(digest: String) async throws -> (any Content)? {
        guard let data = storage[digest] else {
            return nil
        }
        // Return a mock Content object
        return MockContent(data: data)
    }

    public func get<T: Decodable & Sendable>(digest: String) async throws -> T? {
        guard let data = storage[digest] else {
            return nil
        }
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
        var deletedDigests: [String] = []
        var totalSize: UInt64 = 0

        for digest in digests {
            if let data = storage.removeValue(forKey: digest) {
                deletedDigests.append(digest)
                totalSize += UInt64(data.count)
            }
            manifests.removeValue(forKey: digest)
        }

        return (deletedDigests, totalSize)
    }

    @discardableResult
    public func delete(keeping: [String]) async throws -> ([String], UInt64) {
        let keepSet = Set(keeping)
        var deletedDigests: [String] = []
        var totalSize: UInt64 = 0

        for (digest, data) in storage {
            if !keepSet.contains(digest) {
                storage.removeValue(forKey: digest)
                manifests.removeValue(forKey: digest)
                deletedDigests.append(digest)
                totalSize += UInt64(data.count)
            }
        }

        return (deletedDigests, totalSize)
    }

    @discardableResult
    public func ingest(_ body: @Sendable @escaping (URL) async throws -> Void) async throws -> [String] {
        let tempDir = baseDir.appendingPathComponent("ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await body(tempDir)

        // Mock implementation - return empty array
        return []
    }

    public func newIngestSession() async throws -> (id: String, ingestDir: URL) {
        nextSessionId += 1
        let sessionId = "session-\(nextSessionId)"
        let sessionDir = baseDir.appendingPathComponent(sessionId)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        sessions[sessionId] = sessionDir
        return (id: sessionId, ingestDir: sessionDir)
    }

    @discardableResult
    public func completeIngestSession(_ sessionId: String) async throws -> [String] {
        guard let sessionDir = sessions[sessionId] else {
            throw MockContentStoreError.sessionNotFound(sessionId)
        }

        // Read all files from the session directory and store them
        var digests: [String] = []

        if FileManager.default.fileExists(atPath: sessionDir.path) {
            let files = try FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil)
            for file in files {
                let data = try Data(contentsOf: file)
                let digestHash = file.lastPathComponent
                // Ensure the digest has the sha256: prefix for storage
                let digest = digestHash.hasPrefix("sha256:") ? digestHash : "sha256:\(digestHash)"
                storage[digest] = data
                digests.append(digest)
            }
        }

        // Clean up session
        sessions.removeValue(forKey: sessionId)
        try? FileManager.default.removeItem(at: sessionDir)

        return digests
    }

    public func cancelIngestSession(_ sessionId: String) async throws {
        guard let sessionDir = sessions[sessionId] else {
            throw MockContentStoreError.sessionNotFound(sessionId)
        }

        sessions.removeValue(forKey: sessionId)
        try? FileManager.default.removeItem(at: sessionDir)
    }

    // MARK: - Test Utilities

    public func hasContent(digest: String) async -> Bool {
        storage[digest] != nil
    }

    public func clear() async {
        storage.removeAll()
        manifests.removeAll()
        for (_, sessionDir) in sessions {
            try? FileManager.default.removeItem(at: sessionDir)
        }
        sessions.removeAll()
    }

    public func contentCount() async -> Int {
        storage.count
    }
}

// MARK: - Mock ContentStore Errors

public enum MockContentStoreError: LocalizedError {
    case notFound(String)
    case sessionNotFound(String)
    case encodingFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .notFound(let digest):
            return "Content not found: \(digest)"
        case .sessionNotFound(let sessionId):
            return "Session not found: \(sessionId)"
        case .encodingFailed(let error):
            return "Encoding failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Test Data Factory

/// Factory for creating test data objects
public enum TestDataFactory {

    public static func createDigest(from string: String = "test-content") -> ContainerBuildIR.Digest {
        let data = string.data(using: .utf8)!
        return (try? ContainerBuildIR.Digest.compute(data, using: .sha256)) ?? (try! ContainerBuildIR.Digest(algorithm: .sha256, bytes: Data(count: 32)))
    }

    public static func createSnapshot(
        id: UUID = UUID(),
        content: String = "test-snapshot",
        size: Int64 = 1024,
        parent: UUID? = nil
    ) -> Snapshot {
        let digest = createDigest(from: content)
        return Snapshot(
            id: id,
            digest: digest,
            size: size,
            parent: parent
        )
    }

    public static func createCacheKey(
        operation: ContainerBuildIR.Operation? = nil,
        operationContent: String = "test-operation",
        inputContents: [String] = ["input1", "input2"],
        platform: Platform = .linuxAMD64
    ) -> ContainerBuildCache.CacheKey {
        let operationDigest: ContainerBuildIR.Digest
        if let operation = operation {
            operationDigest = (try? operation.contentDigest()) ?? createDigest(from: operationContent)
        } else {
            operationDigest = createDigest(from: operationContent)
        }
        let inputDigests = inputContents.map { createDigest(from: $0) }

        return ContainerBuildCache.CacheKey(
            operationDigest: operationDigest,
            inputDigests: inputDigests,
            platform: platform
        )
    }

    public static func createCachedResult(
        snapshotContent: String = "test-result",
        environmentChanges: [String: EnvironmentValue] = ["PATH": .literal("/usr/bin")],
        metadataChanges: [String: String] = ["build.time": "2024-01-01T12:00:00Z"]
    ) -> CachedResult {
        let snapshot = createSnapshot(content: snapshotContent)
        return CachedResult(
            snapshot: snapshot,
            environmentChanges: environmentChanges,
            metadataChanges: metadataChanges
        )
    }

    public static func createOperation(
        kind: String = "test",
        content: String = "test-operation"
    ) -> MockOperation {
        MockOperation(kind: kind, content: content)
    }

    public static func createCacheConfiguration(
        maxSize: UInt64 = 1024 * 1024,  // 1MB for tests
        maxAge: TimeInterval = 3600,  // 1 hour for tests
        indexPath: URL? = nil
    ) -> CacheConfiguration {
        let testIndexPath =
            indexPath
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("test-cache.db")

        return CacheConfiguration(
            maxSize: maxSize,
            maxAge: maxAge,
            indexPath: testIndexPath,
            evictionPolicy: .lru,
            verifyIntegrity: false,  // Disable for faster tests
            gcInterval: 60  // Short interval for tests
        )
    }

    public static func createCacheMetadata(
        operationHash: String = "test-hash",
        platform: Platform = .linuxAMD64,
        ttl: TimeInterval? = nil,
        tags: [String: String] = [:]
    ) -> CacheMetadata {
        CacheMetadata(
            operationHash: operationHash,
            platform: platform,
            ttl: ttl,
            tags: tags
        )
    }

    public static func createDescriptor(
        mediaType: String = "application/vnd.test+json",
        digest: String = "sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        size: Int64 = 1024
    ) -> Descriptor {
        Descriptor(
            mediaType: mediaType,
            digest: digest,
            size: size,
            urls: nil,
            annotations: nil,
            platform: nil
        )
    }
}

// MARK: - Mock Operation

public struct MockOperation: ContainerBuildIR.Operation {
    public let kind: String
    public let content: String
    public let metadata: OperationMetadata

    public static let operationKind = OperationKind(rawValue: "mock")
    public var operationKind: OperationKind {
        OperationKind(rawValue: kind)
    }

    public init(kind: String = "mock", content: String = "test", metadata: OperationMetadata = OperationMetadata()) {
        self.kind = kind
        self.content = content
        self.metadata = metadata
    }

    public func accept<V: OperationVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visitUnknown(self)
    }
}

extension MockOperation: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(content)
    }

    public static func == (lhs: MockOperation, rhs: MockOperation) -> Bool {
        lhs.kind == rhs.kind && lhs.content == rhs.content
    }
}

// MARK: - Performance Measurement

/// Utility for measuring test performance
public struct PerformanceMeasurement {
    public static func measure<T>(
        _ operation: () async throws -> T,
        file: StaticString = #file,
        line: UInt = #line
    ) async rethrows -> (result: T, duration: TimeInterval) {
        let startTime = Date()
        let result = try await operation()
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)

        print("Performance measurement at \(file):\(line): \(duration)s")
        return (result, duration)
    }

    public static func measureAndAssert<T>(
        _ operation: () async throws -> T,
        maxDuration: TimeInterval,
        file: StaticString = #file,
        line: UInt = #line
    ) async rethrows -> T {
        let (result, duration) = try await measure(operation, file: file, line: line)
        if duration >= maxDuration {
            Issue.record(
                "Operation took too long: \(duration)s >= \(maxDuration)s",
                sourceLocation: SourceLocation(fileID: file.description, filePath: file.description, line: Int(line), column: 1))
        }
        return result
    }
}

// MARK: - Async Test Utilities

/// Utilities for async testing
public enum AsyncTestUtilities {

    /// Wait for a condition to become true with timeout
    public static func waitFor(
        condition: @escaping () async -> Bool,
        timeout: TimeInterval = 5.0,
        interval: TimeInterval = 0.1
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        throw AsyncTestError.timeout
    }

    /// Run multiple async operations concurrently and collect results
    public static func runConcurrently<T: Sendable>(
        count: Int,
        operation: @escaping @Sendable (Int) async throws -> T
    ) async throws -> [T] {
        try await withThrowingTaskGroup(of: T.self) { group in
            for i in 0..<count {
                let index = i
                group.addTask {
                    try await operation(index)
                }
            }

            var results: [T] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }
}

public enum AsyncTestError: LocalizedError {
    case timeout

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Async test timed out"
        }
    }
}
