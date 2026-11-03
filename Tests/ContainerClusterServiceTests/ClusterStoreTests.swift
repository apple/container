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
import Testing

@testable import ContainerClusterService

@Suite("ClusterStore")
struct ClusterStoreTests {
    private func makeStore() -> (ClusterStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        return (ClusterStore(root: dir), dir)
    }

    private func config(_ name: String) -> ClusterConfiguration {
        makeConfig(name)
    }

    @Test func saveThenLoad() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = config("dev")
        try store.save(c)
        #expect(try store.load(name: "dev") == c)
    }

    private func isCaseInsensitive(_ dir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let probe = dir.appending(path: "caseprobe")
        FileManager.default.createFile(atPath: probe.path, contents: Data())
        return FileManager.default.fileExists(atPath: dir.appending(path: "CASEPROBE").path)
    }

    @Test func differentlyCasedNameDoesNotAliasRecord() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = config("dev")
        try store.save(c)
        #expect(try store.load(name: "DEV") == nil)
        try store.remove(name: "DEV")
        #expect(try store.load(name: "dev") == c)
        // The remaining assertions only apply when `DEV` and `dev` share a directory (case-insensitive volumes).
        guard isCaseInsensitive(dir) else { return }
        #expect {
            try store.save(config("DEV"))
        } throws: { error in
            (error as? ContainerizationError)?.code == .exists
        }
        #expect(try store.load(name: "dev") == c)
    }

    @Test func loadMissingReturnsNil() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.load(name: "nope") == nil)
    }

    @Test func loadAllReturnsEveryCluster() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(config("aa"))
        try store.save(config("bb"))
        let names = store.loadAll(log: Logger(label: "test")).map(\.name).sorted()
        #expect(names == ["aa", "bb"])
    }

    @Test func loadAllSkipsCorruptAndUnrelatedEntries() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(config("good"))
        let bad = dir.appending(path: "bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: bad.appending(path: "cluster.json"))
        try Data().write(to: dir.appending(path: "port.lock"))
        try FileManager.default.createDirectory(at: dir.appending(path: "empty"), withIntermediateDirectories: true)
        #expect(store.loadAll(log: Logger(label: "test")).map(\.name) == ["good"])
    }

    @Test func loadAllOnMissingRootIsEmpty() {
        let (store, _) = makeStore()
        #expect(store.loadAll(log: Logger(label: "test")).isEmpty)
    }

    @Test func removeDeletesAndIsIdempotent() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(config("dev"))
        try store.remove(name: "dev")
        #expect(try store.load(name: "dev") == nil)
        try store.remove(name: "dev")  // no throw when already gone
    }

    @Test func removeIgnoresNonClusterEntries() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = dir.appending(path: "port.lock")
        try Data("x".utf8).write(to: lock)
        let plain = dir.appending(path: "plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try store.remove(name: "port.lock")
        try store.remove(name: "plain")
        try store.remove(name: "missing")
        #expect(FileManager.default.fileExists(atPath: lock.path))
        #expect(FileManager.default.fileExists(atPath: plain.path))
    }

    @Test func invalidNamesThrowAndLeaveSiblingsIntact() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(config("dev"))
        let sibling = dir.deletingLastPathComponent().appending(path: "sibling-\(UUID().uuidString)")
        try Data("x".utf8).write(to: sibling)
        defer { try? FileManager.default.removeItem(at: sibling) }
        for bad in ["..", "", ".", "a/b"] {
            #expect(throws: (any Error).self) { try store.remove(name: bad) }
            #expect(throws: (any Error).self) { try store.load(name: bad) }
        }
        #expect(try store.load(name: "dev") != nil)
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    @Test func nameValidAcceptsSafePathComponents() {
        for good in ["a", "dev", "cluster-dev", "my_cluster", "v1.35", "0abc", String(repeating: "a", count: 63)] {
            #expect(ClusterResource.nameValid(good), "\(good) should be valid")
        }
    }

    @Test func nameValidRejectsUnsafeNames() {
        let bad = [
            "", ".", "..", ".hidden", "-dash", "_under", "a/b", "../x", "a\\b", "dev\n", "dev ", "dév", "a\u{0}b",
            String(repeating: "a", count: 64),
        ]
        for name in bad {
            #expect(!ClusterResource.nameValid(name), "\(name.debugDescription) should be invalid")
        }
    }
}
