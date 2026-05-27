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

import ContainerTestSupport
import Foundation
import Logging
import SystemPackage
import Testing

@testable import ContainerPersistence

private struct Item: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var value: String
}

struct FilesystemEntityStoreTests {

    @Test func testListEmpty() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            let items = try await store.list()
            #expect(items.isEmpty)
        }
    }

    @Test func testCreateAndRetrieve() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            try await store.create(Item(id: "foo", value: "hello"))
            let item = try await store.retrieve("foo")
            #expect(item?.value == "hello")
        }
    }

    @Test func testRetrieveNonexistentReturnsNil() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            let result = try await store.retrieve("nope")
            #expect(result == nil)
        }
    }

    @Test func testListAfterCreate() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            try await store.create(Item(id: "a", value: "1"))
            try await store.create(Item(id: "b", value: "2"))
            let items = try await store.list()
            #expect(items.count == 2)
            #expect(Set(items.map(\.id)) == ["a", "b"])
        }
    }

    @Test func testCreateDuplicateThrows() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            try await store.create(Item(id: "dup", value: "x"))
            await #expect(throws: Error.self) {
                try await store.create(Item(id: "dup", value: "y"))
            }
        }
    }

    @Test func testUpdate() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            try await store.create(Item(id: "x", value: "v1"))
            try await store.update(Item(id: "x", value: "v2"))
            let item = try await store.retrieve("x")
            #expect(item?.value == "v2")
        }
    }

    @Test func testUpdateNonexistentThrows() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            await #expect(throws: Error.self) {
                try await store.update(Item(id: "ghost", value: "x"))
            }
        }
    }

    @Test func testDelete() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            try await store.create(Item(id: "del", value: "v"))
            try await store.delete("del")
            let item = try await store.retrieve("del")
            #expect(item == nil)
        }
    }

    @Test func testDeleteRemovesDirectory() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            try await store.create(Item(id: "dir", value: "v"))
            let entityDir = try store.entityPath("dir")
            #expect(FileManager.default.fileExists(atPath: entityDir.string))
            try await store.delete("dir")
            #expect(!FileManager.default.fileExists(atPath: entityDir.string))
        }
    }

    @Test func testDeleteNonexistentThrows() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            await #expect(throws: Error.self) {
                try await store.delete("none")
            }
        }
    }

    @Test func testUpsertCreates() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            try await store.upsert(Item(id: "u", value: "new"))
            let item = try await store.retrieve("u")
            #expect(item?.value == "new")
        }
    }

    @Test func testUpsertUpdates() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            try await store.create(Item(id: "u", value: "old"))
            try await store.upsert(Item(id: "u", value: "new"))
            let item = try await store.retrieve("u")
            #expect(item?.value == "new")
        }
    }

    @Test func testPersistenceAcrossReinit() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store1 = try Self.makeStore(at: path)
            try await store1.create(Item(id: "persist", value: "durable"))

            let store2 = try Self.makeStore(at: path)
            let item = try await store2.retrieve("persist")
            #expect(item?.value == "durable")
        }
    }

    @Test func testEntityPathIsIdUnderRoot() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            let entityPath = try store.entityPath("myentity")
            #expect(entityPath == path.appending("myentity"))
        }
    }

    @Test func testEntityIdWithSlashThrows() async throws {
        try await TemporaryStorage.withTempDir { path in
            let store = try Self.makeStore(at: path)
            await #expect(throws: Error.self) {
                try await store.create(Item(id: "foo/bar", value: "x"))
            }
        }
    }

    private static func makeStore(at path: FilePath) throws -> FilesystemEntityStore<Item> {
        try FilesystemEntityStore<Item>(path: path, type: "item", log: Logger(label: "test"))
    }
}
