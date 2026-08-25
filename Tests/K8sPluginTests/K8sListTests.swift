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
import Foundation
import Testing
import Yams

@testable import ContainerK8s

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
    let labelsJSON = #"{"com.apple.container.plugin":"k8s","com.apple.container.resource.role":"\#(role)"}"#
    let networksJSON: String
    if addr.isEmpty {
        networksJSON = "[]"
    } else {
        networksJSON = #"[{"network":"bridge","hostname":"\#(id)","ipv4Address":"\#(addr)/24","ipv4Gateway":"10.0.0.254"}]"#
    }
    let json = """
        {
            "configuration": {
                "id": "\(id)",
                "image": {
                    "reference": "docker.io/kindest/node:v1.35.5",
                    "descriptor": {"mediaType":"","digest":"sha256:abc","size":0}
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
    try makeSnapshot(id: name, role: K8sHelper.controlPlaneRoleName, cpus: cpus, memoryMiB: memoryMiB, addr: addr)
}

private func makeWorker(_ id: String, cpus: Int = max(fixtureDefaultCPUs / 2, 1), memoryMiB: UInt64 = max(fixtureDefaultMemoryMiB / 2, 512)) throws -> ContainerSnapshot {
    try makeSnapshot(id: id, role: "worker", cpus: cpus, memoryMiB: memoryMiB)
}

// MARK: - K8sNodeResource header / row shape

@Suite("K8sNodeResource")
struct K8sNodeRowTests {
    @Test func tableHeaderHasEightColumns() throws {
        #expect(K8sNodeResource.tableHeader.count == 8)
    }

    @Test func tableHeaderLabels() throws {
        #expect(K8sNodeResource.tableHeader == ["CLUSTER", "NODE", "ROLE", "STATE", "CPUS", "MEMORY", "ADDR", "PORTS"])
    }

    @Test func rowColumnCountMatchesHeader() throws {
        let snapshot = try makeControlPlane("dev")
        let row = K8sNodeResource(clusterName: "dev", snapshot: snapshot)
        #expect(row.tableRow.count == K8sNodeResource.tableHeader.count)
    }

    @Test func controlPlaneRowValues() throws {
        let cpus = fixtureDefaultCPUs
        let memoryMiB = fixtureDefaultMemoryMiB
        let snapshot = try makeControlPlane("dev", cpus: cpus, memoryMiB: memoryMiB, addr: "10.0.0.1")
        let row = K8sNodeResource(clusterName: "dev", snapshot: snapshot)
        let cols = row.tableRow
        #expect(cols[0] == "dev")  // CLUSTER
        #expect(cols[1] == "dev")  // NODE
        #expect(cols[2] == K8sHelper.controlPlaneRoleName)  // ROLE
        #expect(cols[3] == "running")  // STATE
        #expect(cols[4] == "\(cpus)")  // CPUS
        #expect(cols[5] == "\(memoryMiB) MB")  // MEMORY
        #expect(cols[6].contains("10.0.0.1"))  // ADDR
        // cols[7] PORTS: no publishedPorts in fixture → empty string
        #expect(cols[7] == "")
    }

    @Test func workerRowValues() throws {
        let cpus = max(fixtureDefaultCPUs / 2, 1)
        let memoryMiB = max(fixtureDefaultMemoryMiB / 2, 512)
        let snapshot = try makeWorker("dev-worker-1", cpus: cpus, memoryMiB: memoryMiB)
        let row = K8sNodeResource(clusterName: "dev", snapshot: snapshot)
        let cols = row.tableRow
        #expect(cols[0] == "dev")  // CLUSTER
        #expect(cols[1] == "dev-worker-1")  // NODE
        #expect(cols[2] == "worker")  // ROLE
        #expect(cols[4] == "\(cpus)")  // CPUS
        #expect(cols[5] == "\(memoryMiB) MB")  // MEMORY
    }

    @Test func quietValueIsNodeID() throws {
        let snapshot = try makeWorker("dev-worker-2")
        let row = K8sNodeResource(clusterName: "dev", snapshot: snapshot)
        #expect(row.quietValue == "dev-worker-2")
    }
}

// MARK: - buildK8sRows ordering and grouping

@Suite("K8sHelper.buildK8sRows")
struct BuildK8sRowsTests {
    @Test func emptyInputProducesNoRows() {
        #expect(K8sHelper.buildK8sRows(from: []).isEmpty)
    }

    @Test func singleControlPlaneAlone() throws {
        let cp = try makeControlPlane("dev")
        let rows = K8sHelper.buildK8sRows(from: [cp])
        #expect(rows.count == 1)
        #expect(rows[0].snapshot.configuration.id == "dev")
    }

    @Test func controlPlaneFollowedByItsWorkers() throws {
        let cp = try makeControlPlane("dev")
        let w1 = try makeWorker("dev-worker-1")
        let w2 = try makeWorker("dev-worker-2")
        let rows = K8sHelper.buildK8sRows(from: [w2, w1, cp])
        #expect(rows.count == 3)
        #expect(rows[0].snapshot.id == "dev")
        #expect(rows[1].snapshot.id == "dev-worker-1")
        #expect(rows[2].snapshot.id == "dev-worker-2")
    }

    @Test func workersGroupedUnderCorrectControlPlane() throws {
        let cp1 = try makeControlPlane("alpha")
        let cp2 = try makeControlPlane("beta")
        let w1 = try makeWorker("alpha-worker-1")
        let w2 = try makeWorker("beta-worker-1")
        let rows = K8sHelper.buildK8sRows(from: [w2, cp2, w1, cp1])
        #expect(rows[0].snapshot.id == "alpha")
        #expect(rows[1].snapshot.id == "alpha-worker-1")
        #expect(rows[1].clusterName == "alpha")
        #expect(rows[2].snapshot.id == "beta")
        #expect(rows[3].snapshot.id == "beta-worker-1")
        #expect(rows[3].clusterName == "beta")
    }

    @Test func multipleClustersAreSortedByName() throws {
        let cpZ = try makeControlPlane("zebra")
        let cpA = try makeControlPlane("apple")
        let rows = K8sHelper.buildK8sRows(from: [cpZ, cpA])
        #expect(rows[0].snapshot.id == "apple")
        #expect(rows[1].snapshot.id == "zebra")
    }

    @Test func orphanedWorkerAppearsAtEnd() throws {
        let cp = try makeControlPlane("dev")
        let orphan = try makeWorker("old-worker-1")
        let rows = K8sHelper.buildK8sRows(from: [orphan, cp])
        #expect(rows.count == 2)
        #expect(rows[0].snapshot.id == "dev")
        #expect(rows[1].snapshot.id == "old-worker-1")
        #expect(rows[1].clusterName == "old")
    }

    @Test func orphanedWorkerClusterNameDerivedFromID() throws {
        let orphan = try makeWorker("mycluster-worker-3")
        let rows = K8sHelper.buildK8sRows(from: [orphan])
        #expect(rows.count == 1)
        #expect(rows[0].clusterName == "mycluster")
    }

    @Test func clusterNameWithWorkerInItIsHandledCorrectly() throws {
        let cp = try makeControlPlane("foo-worker")
        let w = try makeWorker("foo-worker-worker-1")
        let rows = K8sHelper.buildK8sRows(from: [w, cp])
        #expect(rows.count == 2)
        #expect(rows[0].snapshot.id == "foo-worker")
        #expect(rows[1].snapshot.id == "foo-worker-worker-1")
        #expect(rows[1].clusterName == "foo-worker")
    }

    @Test func workerNotAssignedToWrongCluster() throws {
        let cp = try makeControlPlane("dev")
        let w = try makeWorker("dev2-worker-1")
        let rows = K8sHelper.buildK8sRows(from: [w, cp])
        #expect(rows[0].snapshot.id == "dev")
        #expect(rows[1].snapshot.id == "dev2-worker-1")
        #expect(rows[1].clusterName == "dev2")
    }
}

// MARK: - K8sHelper.fqdn

@Suite("K8sHelper.fqdn")
struct FQDNTests {
    @Test func nilDomainReturnsNil() {
        #expect(K8sHelper.fqdn(for: "dev", domain: nil) == nil)
    }

    @Test func emptyDomainReturnsNil() {
        #expect(K8sHelper.fqdn(for: "dev", domain: "") == nil)
    }

    @Test func nameWithDotReturnedAsIs() {
        #expect(K8sHelper.fqdn(for: "dev.local", domain: "example.com") == "dev.local")
    }

    @Test func plainNameGetsDomainAppended() {
        #expect(K8sHelper.fqdn(for: "dev", domain: "example.com") == "dev.example.com")
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
