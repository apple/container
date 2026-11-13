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

import ContainerResource
import ContainerizationError
import Foundation
import SystemPackage
import Testing

@testable import ContainerCluster

private func makeSnapshot(id: String, status: RuntimeStatus, virtiofsSource: String? = nil) throws -> ContainerSnapshot {
    var mounts = "[]"
    if let virtiofsSource {
        mounts = #"[{"type":{"virtiofs":{}},"source":"\#(virtiofsSource)","destination":"/data","options":[]}]"#
    }
    let sha = "sha256:" + String(repeating: "a", count: 64)
    let json = """
        {
            "configuration": {
                "id": "\(id)",
                "image": {
                    "reference": "docker.io/kindest/node:v1.35.5",
                    "descriptor": {"mediaType":"","digest":"\(sha)","size":0}
                },
                "initProcess": {
                    "executable":"/bin/sh","arguments":[],"environment":[],"workingDirectory":"/","terminal":false,
                    "user":{"id":{"uid":0,"gid":0}},"supplementalGroups":[],"rlimits":[]
                },
                "resources": {"cpus":2,"memoryInBytes":2147483648},
                "mounts": \(mounts),
                "labels": {"com.apple.container.plugin":"cluster"}
            },
            "status": "\(status.rawValue)",
            "networks": []
        }
        """
    return try JSONDecoder().decode(ContainerSnapshot.self, from: Data(json.utf8))
}

private func makeConfiguration(workers: UInt, sharedImageStore: Bool = false) throws -> ClusterConfiguration {
    try ClusterConfiguration.make(
        name: "dev", nodeImage: "docker.io/kindest/node:v1.35.5", remove: false, sharedImageStore: sharedImageStore,
        workers: workers, cni: nil, fqdn: nil)
}

@Suite("ClusterHelper.nodesToStart")
struct ClusterNodeSelectionTests {
    @Test func nodesToStartReturnsStoppedNodesInConfigurationOrder() throws {
        let configuration = try makeConfiguration(workers: 2)
        let snapshots = [
            try makeSnapshot(id: "dev-worker-2", status: .stopped),
            try makeSnapshot(id: "dev-worker-1", status: .running),
            try makeSnapshot(id: "dev", status: .stopped),
        ]

        let names = try ClusterHelper.nodesToStart(configuration: configuration, snapshots: snapshots)

        #expect(names == ["dev", "dev-worker-2"])
    }

    @Test func nodesToStartReturnsNothingWhenAllNodesRun() throws {
        let configuration = try makeConfiguration(workers: 1)
        let snapshots = [
            try makeSnapshot(id: "dev", status: .running),
            try makeSnapshot(id: "dev-worker-1", status: .running),
        ]

        let names = try ClusterHelper.nodesToStart(configuration: configuration, snapshots: snapshots)

        #expect(names.isEmpty)
    }

    @Test func nodesToStartThrowsWhenNodeContainerIsMissing() throws {
        let configuration = try makeConfiguration(workers: 1)
        let snapshots = [try makeSnapshot(id: "dev", status: .stopped)]

        let error = #expect(throws: ContainerizationError.self) {
            try ClusterHelper.nodesToStart(configuration: configuration, snapshots: snapshots)
        }
        #expect(error?.code == .notFound)
    }
}

@Suite("ClusterHelper.nodesToStop")
struct NodesToStopTests {
    @Test func nodesToStopReturnsRunningNodesInConfigurationOrder() throws {
        let configuration = try makeConfiguration(workers: 2)
        let snapshots = [
            try makeSnapshot(id: "dev-worker-2", status: .running),
            try makeSnapshot(id: "dev-worker-1", status: .stopped),
            try makeSnapshot(id: "dev", status: .running),
        ]

        let names = ClusterHelper.nodesToStop(configuration: configuration, snapshots: snapshots)

        #expect(names == ["dev", "dev-worker-2"])
    }

    @Test func nodesToStopSkipsMissingContainers() throws {
        let configuration = try makeConfiguration(workers: 1)
        let snapshots = [try makeSnapshot(id: "dev", status: .running)]

        let names = ClusterHelper.nodesToStop(configuration: configuration, snapshots: snapshots)

        #expect(names == ["dev"])
    }
}

@Suite("ClusterHelper.checkNodeStartPrerequisites")
struct NodeStartPrerequisitesTests {
    private let hostStoreSocketPath = FilePath("/nonexistent/hoststore.sock")

    @Test func prerequisitesFailWhenHostStoreSocketIsMissing() throws {
        let configuration = try makeConfiguration(workers: 0, sharedImageStore: true)
        let snapshots = [try makeSnapshot(id: "dev", status: .stopped)]
        let socketPath = FilePath("/nonexistent-\(UUID().uuidString)/hoststore.sock")

        let error = #expect(throws: ContainerizationError.self) {
            try ClusterHelper.checkNodeStartPrerequisites(
                configuration: configuration, snapshots: snapshots, toStart: ["dev"], hostStoreSocketPath: socketPath)
        }
        #expect(error?.code == .notFound)
    }

    @Test func prerequisitesPassWhenHostStoreSocketExists() throws {
        let configuration = try makeConfiguration(workers: 0, sharedImageStore: true)
        let snapshots = [try makeSnapshot(id: "dev", status: .stopped)]
        let socketPath = FilePath(FileManager.default.temporaryDirectory.path).appending("hoststore-test-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: socketPath.string, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: socketPath.string) }

        try ClusterHelper.checkNodeStartPrerequisites(
            configuration: configuration, snapshots: snapshots, toStart: ["dev"], hostStoreSocketPath: socketPath)
    }

    @Test func prerequisitesIgnoreHostStoreSocketWithoutSharedImageStore() throws {
        let configuration = try makeConfiguration(workers: 0)
        let snapshots = [try makeSnapshot(id: "dev", status: .stopped)]

        try ClusterHelper.checkNodeStartPrerequisites(
            configuration: configuration, snapshots: snapshots, toStart: ["dev"], hostStoreSocketPath: FilePath("/nonexistent/hoststore.sock"))
    }

    @Test func prerequisitesFailWhenVirtiofsMountSourceIsMissing() throws {
        let configuration = try makeConfiguration(workers: 0)
        let missing = "/nonexistent-\(UUID().uuidString)"
        let snapshots = [try makeSnapshot(id: "dev", status: .stopped, virtiofsSource: missing)]

        let error = #expect(throws: ContainerizationError.self) {
            try ClusterHelper.checkNodeStartPrerequisites(
                configuration: configuration, snapshots: snapshots, toStart: ["dev"], hostStoreSocketPath: hostStoreSocketPath)
        }
        #expect(error?.code == .invalidState)
    }

    @Test func prerequisitesIgnoreMountsOfNodesNotBeingStarted() throws {
        let configuration = try makeConfiguration(workers: 1)
        let missing = "/nonexistent-\(UUID().uuidString)"
        let snapshots = [
            try makeSnapshot(id: "dev", status: .running, virtiofsSource: missing),
            try makeSnapshot(id: "dev-worker-1", status: .stopped),
        ]

        try ClusterHelper.checkNodeStartPrerequisites(configuration: configuration, snapshots: snapshots, toStart: ["dev-worker-1"], hostStoreSocketPath: hostStoreSocketPath)
    }
}

@Suite("ClusterHelper.workersToRestart")
struct WorkersToRestartTests {
    @Test func workersToRestartReturnsRunningWorkersWhenControlPlaneStartsWithoutFQDN() throws {
        let configuration = try makeConfiguration(workers: 2)
        let snapshots = [
            try makeSnapshot(id: "dev", status: .stopped),
            try makeSnapshot(id: "dev-worker-1", status: .running),
            try makeSnapshot(id: "dev-worker-2", status: .running),
        ]

        let names = ClusterHelper.workersToRestart(configuration: configuration, snapshots: snapshots, controlPlaneStarting: true)

        #expect(names == ["dev-worker-1", "dev-worker-2"])
    }

    @Test func workersToRestartIsEmptyWhenFQDNIsSet() throws {
        let configuration = try ClusterConfiguration.make(
            name: "dev", nodeImage: "docker.io/kindest/node:v1.35.5", remove: false,
            workers: 1, cni: nil, fqdn: "dev.example.test")
        let snapshots = [
            try makeSnapshot(id: "dev", status: .stopped),
            try makeSnapshot(id: "dev-worker-1", status: .running),
        ]

        let names = ClusterHelper.workersToRestart(configuration: configuration, snapshots: snapshots, controlPlaneStarting: true)

        #expect(names.isEmpty)
    }

    @Test func workersToRestartIsEmptyWhenControlPlaneIsNotStarting() throws {
        let configuration = try makeConfiguration(workers: 1)
        let snapshots = [
            try makeSnapshot(id: "dev", status: .running),
            try makeSnapshot(id: "dev-worker-1", status: .running),
        ]

        let names = ClusterHelper.workersToRestart(configuration: configuration, snapshots: snapshots, controlPlaneStarting: false)

        #expect(names.isEmpty)
    }

    @Test func workersToRestartIgnoresStoppedWorkers() throws {
        let configuration = try makeConfiguration(workers: 2)
        let snapshots = [
            try makeSnapshot(id: "dev", status: .stopped),
            try makeSnapshot(id: "dev-worker-1", status: .stopped),
            try makeSnapshot(id: "dev-worker-2", status: .running),
        ]

        let names = ClusterHelper.workersToRestart(configuration: configuration, snapshots: snapshots, controlPlaneStarting: true)

        #expect(names == ["dev-worker-2"])
    }
}
