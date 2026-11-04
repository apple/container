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
import SystemPackage
import Testing

@testable import ContainerClusterService

@Suite("ClusterService")
struct ClusterServiceTests {
    private func makeRoot() -> FilePath {
        FilePath(FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path)
    }

    private func removeRoot(_ root: FilePath) {
        try? FileManager.default.removeItem(atPath: root.string)
    }

    private func makeService(root: FilePath, snapshots: [ContainerSnapshot] = []) throws -> ClusterService {
        try ClusterService(root: root, listContainers: { snapshots }, log: Logger(label: "test"))
    }

    private func expectCode(_ code: ContainerizationError.Code, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected error \(code)")
        } catch let error as ContainerizationError {
            #expect(error.code == code)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func createNewThenGet() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(root: root, snapshots: [try makeControlPlane("dev")])
        let config = makeConfig("dev")
        try await service.create(config)
        let info = try await service.get(name: "dev")
        #expect(info.status.state == .running)
        #expect(info.configuration == config)
    }

    @Test func createDuplicateWithLiveNodeThrowsExists() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(root: root, snapshots: [try makeControlPlane("dev")])
        let config = makeConfig("dev")
        try await service.create(config)
        do {
            try await service.create(makeConfig("dev", workers: 1))
            Issue.record("expected error")
        } catch let error as ContainerizationError {
            #expect(error.code == .exists)
            #expect(error.message.contains("container cluster delete --name dev"))
        }
        #expect(try await service.get(name: "dev").configuration == config)
    }

    private actor ServiceBox {
        private var service: ClusterService?

        func set(_ service: ClusterService) {
            self.service = service
        }

        func deleteRecord(named name: String) async throws {
            try await service?.delete(name: name)
        }
    }

    @Test func createSucceedsWhenRecordDeletedDuringListing() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let box = ServiceBox()
        let service = try ClusterService(
            root: root,
            listContainers: {
                try await box.deleteRecord(named: "dev")
                return []
            }, log: Logger(label: "test"))
        await box.set(service)
        try await service.create(makeConfig("dev"))
        let replacement = makeConfig("dev", workers: 1)
        try await service.create(replacement)
        #expect(try await service.get(name: "dev").configuration == replacement)
    }

    @Test func createReplacesStaleRecord() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(root: root)
        try await service.create(makeConfig("dev"))
        let replacement = makeConfig("dev", workers: 1)
        try await service.create(replacement)
        #expect(try await service.get(name: "dev").configuration == replacement)
    }

    private struct ListFailure: Error {}

    @Test func createLeavesRecordWhenListFails() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let config = makeConfig("dev")
        try await makeService(root: root).create(config)
        let failing = try ClusterService(root: root, listContainers: { throw ListFailure() }, log: Logger(label: "test"))
        do {
            try await failing.create(makeConfig("dev", workers: 1))
            Issue.record("expected error")
        } catch is ListFailure {
        }
        #expect(try await makeService(root: root).get(name: "dev").configuration == config)
    }

    @Test func getMissingThrowsNotFound() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(root: root)
        await expectCode(.notFound) { _ = try await service.get(name: "nope") }
    }

    @Test func listIsSortedAndJoinsContainers() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(root: root, snapshots: [try makeControlPlane("bb")])
        try await service.create(makeConfig("bb"))
        try await service.create(makeConfig("aa"))
        let infos = try await service.list()
        #expect(infos.map(\.configuration.name) == ["aa", "bb"])
        #expect(infos[0].status.state != .running)
        #expect(infos[1].status.state == .running)
    }

    @Test func deleteRemovesAndIsIdempotent() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(root: root)
        try await service.create(makeConfig("dev"))
        try await service.delete(name: "dev")
        try await service.delete(name: "dev")
        #expect(try await service.list().isEmpty)
    }

    @Test func deleteLeavesNonClusterEntriesAlone() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(root: root)
        let lock = root.appending("port.lock")
        try Data("x".utf8).write(to: URL(filePath: lock.string))
        let plain = root.appending("plain")
        try FileManager.default.createDirectory(atPath: plain.string, withIntermediateDirectories: true)
        try await service.delete(name: "port.lock")
        try await service.delete(name: "plain")
        try await service.delete(name: "missing")
        #expect(FileManager.default.fileExists(atPath: lock.string))
        #expect(FileManager.default.fileExists(atPath: plain.string))
    }

    @Test func deleteInvalidNameThrowsAndLeavesSiblingsIntact() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(root: root)
        let config = makeConfig("dev")
        try await service.create(config)
        let sibling = root.removingLastComponent().appending("sibling-\(UUID().uuidString)")
        try Data("x".utf8).write(to: URL(filePath: sibling.string))
        defer { try? FileManager.default.removeItem(atPath: sibling.string) }
        for bad in ["..", "", ".", "a/b"] {
            await expectCode(.invalidArgument) { try await service.delete(name: bad) }
        }
        #expect(try await service.get(name: "dev").configuration == config)
        #expect(FileManager.default.fileExists(atPath: sibling.string))
    }
}
