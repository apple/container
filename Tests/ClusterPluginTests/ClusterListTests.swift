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
import Foundation
import Testing
import Yams

@testable import ContainerCluster

// MARK: - Fixtures

private let fixtureDefaultCPUs: Int = max(ProcessInfo.processInfo.processorCount / 4, 2)
private let fixtureDefaultMemoryMiB: UInt64 = {
    let gb = max(Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) / 4, 2)
    return UInt64(gb * 1024)
}()

private func makeSnapshot(
    id: String,
    role: String,
    status: RuntimeStatus = .running,
    cpus: Int = 2,
    memoryMiB: UInt64 = 2048,
    addr: String = ""
) throws -> ContainerSnapshot {
    let labelsJSON = #"{"com.apple.container.plugin":"cluster","com.apple.container.resource.role":"\#(role)"}"#
    let networksJSON: String
    if addr.isEmpty {
        networksJSON = "[]"
    } else {
        networksJSON = #"[{"network":"bridge","hostname":"\#(id)","ipv4Address":"\#(addr)/24","ipv4Gateway":"10.0.0.254"}]"#
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
                "initProcess": {"executable":"/bin/sh","arguments":[],"environment":[],"workingDirectory":"/","terminal":false,"user":{"id":{"uid":0,"gid":0}},"supplementalGroups":[],"rlimits":[]},
                "resources": {"cpus":\(cpus),"memoryInBytes":\(memoryMiB * 1024 * 1024)},
                "labels": \(labelsJSON)
            },
            "status": "\(status.rawValue)",
            "networks": \(networksJSON)
        }
        """
    return try JSONDecoder().decode(ContainerSnapshot.self, from: Data(json.utf8))
}

private func makeControlPlane(_ name: String, cpus: Int = fixtureDefaultCPUs, memoryMiB: UInt64 = fixtureDefaultMemoryMiB, addr: String = "") throws -> ContainerSnapshot {
    try makeSnapshot(id: name, role: ClusterHelper.controlPlaneRoleName, cpus: cpus, memoryMiB: memoryMiB, addr: addr)
}

private func makeWorker(_ id: String, cpus: Int = max(fixtureDefaultCPUs / 2, 1), memoryMiB: UInt64 = max(fixtureDefaultMemoryMiB / 2, 512)) throws -> ContainerSnapshot {
    try makeSnapshot(id: id, role: "worker", cpus: cpus, memoryMiB: memoryMiB)
}

// MARK: - Cluster list state derivation and renderers

private func makeConfig(_ name: String, workers: UInt = 0) throws -> ClusterConfiguration {
    try ClusterConfiguration.make(
        name: name, nodeImage: "docker.io/kindest/node:v1.35.5", remove: false, workers: workers, cni: nil, fqdn: nil)
}

@Suite("ClusterResource table")
struct ClusterResourceTableTests {
    @Test func headerAndRow() throws {
        let info = ClusterResource(
            configuration: try makeConfig("dev"),
            status: ClusterStatus(
                state: .running,
                nodes: [ClusterNodeState(name: "dev", status: .running)]))
        #expect(ClusterResource.tableHeader == ["NAME", "NODES", "K8S VERSION", "STATE"])
        #expect(info.tableRow == ["dev", "1", "v1.35.5", "running"])
        #expect(info.quietValue == "dev")
    }

    @Test func degradedAndStoppedStateText() throws {
        let degraded = ClusterResource(
            configuration: try makeConfig("dev", workers: 1),
            status: ClusterStatus(
                state: .degraded,
                nodes: [
                    ClusterNodeState(name: "dev", status: .running),
                    ClusterNodeState(name: "dev-worker-1", status: .stopped),
                ]))
        #expect(degraded.tableRow[3] == "degraded (1 of 2 up)")
        let stopped = ClusterResource(
            configuration: try makeConfig("dev"),
            status: ClusterStatus(
                state: .stopped,
                nodes: [ClusterNodeState(name: "dev", status: .stopped)]))
        #expect(stopped.tableRow[3] == "stopped")
    }
}

@Suite("ClusterNodeRow")
struct ClusterNodeRowTests {
    @Test func headerLabels() {
        #expect(ClusterNodeRow.tableHeader == ["CLUSTER", "NODE", "ROLE", "STATE", "CPUS", "MEMORY", "ADDR", "PORTS"])
    }

    @Test func rowsIncludeResourcesFromSnapshots() throws {
        let infos = [
            ClusterResource(
                configuration: try makeConfig("dev", workers: 1),
                status: ClusterStatus(
                    state: .degraded,
                    nodes: [
                        ClusterNodeState(name: "dev", status: .running, addresses: ["10.0.0.1"]),
                        ClusterNodeState(name: "dev-worker-1", status: .stopped),
                    ]))
        ]
        let rows = ClusterHelper.buildNodeRows(
            infos: infos,
            snapshots: [
                try makeControlPlane("dev", cpus: 4, memoryMiB: 4096, addr: "10.0.0.1"),
                try makeSnapshot(id: "dev-worker-1", role: "worker", status: .stopped, cpus: 2, memoryMiB: 512),
            ])
        #expect(rows.count == 2)
        #expect(rows[0].tableRow == ["dev", "dev", "control-plane", "running", "4", "4 GB", "10.0.0.1", ""])
        #expect(rows[1].tableRow == ["dev", "dev-worker-1", "worker", "stopped", "2", "512 MB", "", ""])
        #expect(rows[1].quietValue == "dev-worker-1")
    }

    @Test func rowsMatchNodeStatesByNameNotPosition() throws {
        let infos = [
            ClusterResource(
                configuration: try makeConfig("dev", workers: 1),
                status: ClusterStatus(
                    state: .degraded,
                    nodes: [
                        ClusterNodeState(name: "dev-worker-1", status: .stopped),
                        ClusterNodeState(name: "dev", status: .running, addresses: ["10.0.0.1"]),
                    ]))
        ]
        let rows = ClusterHelper.buildNodeRows(infos: infos, snapshots: [])
        #expect(rows.map(\.node.name) == ["dev", "dev-worker-1"])
        #expect(rows[0].tableRow[3] == "running")
        #expect(rows[0].tableRow[6] == "10.0.0.1")
        #expect(rows[1].tableRow[3] == "stopped")
    }

    @Test func missingContainerHasBlankResources() throws {
        let infos = [
            ClusterResource(
                configuration: try makeConfig("dev"),
                status: ClusterStatus(
                    state: .stopped,
                    nodes: [ClusterNodeState(name: "dev", status: .stopped)]))
        ]
        let rows = ClusterHelper.buildNodeRows(infos: infos, snapshots: [])
        #expect(rows[0].tableRow == ["dev", "dev", "control-plane,worker", "stopped", "", "", "", ""])
    }
}

// MARK: - ClusterHelper.workerContainerNames

@Suite("ClusterHelper.workerContainerNames")
struct WorkerContainerNamesTests {
    @Test func emptyInputProducesNoNames() {
        #expect(ClusterHelper.workerContainerNames(from: [], clusterName: "dev").isEmpty)
    }

    @Test func excludesControlPlane() throws {
        let cp = try makeControlPlane("dev")
        let names = ClusterHelper.workerContainerNames(from: [cp], clusterName: "dev")
        #expect(names.isEmpty)
    }

    @Test func includesMatchingWorkers() throws {
        let cp = try makeControlPlane("dev")
        let w1 = try makeWorker("dev-worker-1")
        let w2 = try makeWorker("dev-worker-2")
        let names = ClusterHelper.workerContainerNames(from: [cp, w2, w1], clusterName: "dev")
        #expect(names == ["dev-worker-1", "dev-worker-2"])
    }

    @Test func excludesWorkersFromOtherClusters() throws {
        let w1 = try makeWorker("dev-worker-1")
        let other = try makeWorker("dev2-worker-1")
        let names = ClusterHelper.workerContainerNames(from: [w1, other], clusterName: "dev")
        #expect(names == ["dev-worker-1"])
    }
}

// MARK: - ClusterHelper.fqdn

@Suite("ClusterHelper.fqdn")
struct FQDNTests {
    @Test func nilDomainReturnsNil() {
        #expect(ClusterHelper.fqdn(for: "dev", domain: nil) == nil)
    }

    @Test func emptyDomainReturnsNil() {
        #expect(ClusterHelper.fqdn(for: "dev", domain: "") == nil)
    }

    @Test func nameWithDotReturnedAsIs() {
        #expect(ClusterHelper.fqdn(for: "dev.local", domain: "example.com") == "dev.local")
    }

    @Test func plainNameGetsDomainAppended() {
        #expect(ClusterHelper.fqdn(for: "dev", domain: "example.com") == "dev.example.com")
    }
}

// MARK: - KubeConfig

@Suite("KubeConfig")
struct KubeKubeConfigTests {
    private func sampleYAML(clusterName: String = "default") -> String {
        """
        apiVersion: v1
        kind: Config
        clusters:
        - name: \(clusterName)
          cluster:
            server: https://127.0.0.1:6443
            certificate-authority-data: dGVzdA==
        contexts:
        - name: \(clusterName)
          context:
            cluster: \(clusterName)
            user: \(clusterName)
        current-context: \(clusterName)
        users:
        - name: \(clusterName)
          user:
            client-certificate-data: dGVzdA==
            client-key-data: dGVzdA==
        """
    }

    @Test func decodeRoundTrip() throws {
        let config = try YAMLDecoder().decode(KubeConfig.self, from: sampleYAML())
        #expect(config.apiVersion == "v1")
        #expect(config.kind == "Config")
        #expect(config.clusters.count == 1)
        #expect(config.clusters[0].cluster.server == "https://127.0.0.1:6443")
        #expect(config.contexts.count == 1)
        #expect(config.users.count == 1)
        #expect(config.currentContext == "default")
    }

    @Test func emptyConfigEncodesWithoutError() throws {
        let output = try YAMLEncoder().encode(KubeConfig.empty)
        #expect(!output.isEmpty)
    }
}
