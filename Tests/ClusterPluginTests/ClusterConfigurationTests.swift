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

@testable import ContainerCluster

@Suite("ClusterConfiguration")
struct ClusterConfigurationTests {
    private let image = "docker.io/kindest/node:v1.35.5@sha256:abc"

    @Test func makeWithoutWorkersHasSingleDualRoleNode() throws {
        let c = try ClusterConfiguration.make(
            name: "dev", nodeImage: image, remove: false, workers: 0, cni: nil, fqdn: nil)
        #expect(c.kubernetesVersion == "v1.35.5")
        #expect(c.nodes.count == 1)
        #expect(c.nodes[0].name == "dev")
        #expect(c.nodes[0].roles == ["control-plane", "worker"])
        #expect(!c.remove)
    }

    @Test func makeWithWorkersAddsNamedWorkers() throws {
        let c = try ClusterConfiguration.make(
            name: "dev", nodeImage: image, remove: true, workers: 2, cni: "NONE", fqdn: "dev.test")
        #expect(c.nodes.map(\.name) == ["dev", "dev-worker-1", "dev-worker-2"])
        #expect(c.nodes[0].roles == ["control-plane"])
        #expect(c.nodes[1].roles == ["worker"])
        #expect(c.nodes.allSatisfy { $0.kind == .linux })
        #expect(c.remove)
        #expect(c.cni == "NONE")
        #expect(c.fqdn == "dev.test")
    }

    @Test func makeRejectsUntaggedImage() {
        #expect(throws: (any Error).self) {
            _ = try ClusterConfiguration.make(
                name: "dev", nodeImage: "docker.io/kindest/node", remove: false, workers: 0, cni: nil, fqdn: nil)
        }
    }

    @Test func absentOptionalsEncodeAsNull() throws {
        let c = try ClusterConfiguration.make(
            name: "dev", nodeImage: image, remove: false, workers: 0, cni: nil, fqdn: nil)
        let json = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(json.contains(#""cni":null"#))
        #expect(json.contains(#""fqdn":null"#))
    }

    @Test func tomlRenderingDoesNotThrowForAbsentOptionals() throws {
        let c = try ClusterConfiguration.make(
            name: "dev", nodeImage: image, remove: false, workers: 0, cni: nil, fqdn: nil)
        let info = ClusterResource(configuration: c, status: ClusterStatus(state: .stopped, nodes: [ClusterNodeState(name: "dev", status: .stopped)]))
        let toml = try Output.renderTOML([info])
        #expect(toml.contains("dev"))
        let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        #expect(json.contains(#""cni":null"#))
    }

    @Test func codableRoundTrip() throws {
        let c = try ClusterConfiguration.make(
            name: "dev", nodeImage: image, remove: false, workers: 1, cni: "/tmp/cni.yaml", fqdn: nil)
        let decoded = try JSONDecoder().decode(ClusterConfiguration.self, from: JSONEncoder().encode(c))
        #expect(decoded == c)
    }

    @Test func clusterResourceOmitsEmptyNodeAddressesAndPorts() throws {
        let c = try ClusterConfiguration.make(
            name: "dev", nodeImage: image, remove: false, workers: 0, cni: nil, fqdn: nil)
        let info = ClusterResource(configuration: c, status: ClusterStatus(state: .stopped, nodes: [ClusterNodeState(name: "dev", status: .stopped)]))
        let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        #expect(json.contains(#""state":"stopped""#))
        #expect(!json.contains("addresses"))
        #expect(!json.contains(#""ports""#))
    }

    @Test func makeRejectsTooManyWorkers() {
        #expect(throws: (any Error).self) {
            _ = try ClusterConfiguration.make(
                name: "dev", nodeImage: image, remove: false, workers: ClusterConfiguration.maxWorkers + 1, cni: nil, fqdn: nil)
        }
    }

    @Test func makeRejectsInvalidClusterName() {
        #expect(throws: (any Error).self) {
            _ = try ClusterConfiguration.make(name: "../evil", nodeImage: image, remove: false, workers: 0, cni: nil, fqdn: nil)
        }
    }

    @Test func initRejectsDuplicateNodeNames() throws {
        let node = try NodeConfiguration(name: "dev", roles: ["control-plane"])
        #expect(throws: (any Error).self) {
            _ = try ClusterConfiguration(name: "dev", kubernetesVersion: "v1.35.5", nodes: [node, node])
        }
    }

    @Test func initRejectsNoNodes() {
        #expect(throws: (any Error).self) {
            _ = try ClusterConfiguration(name: "dev", kubernetesVersion: "v1.35.5", nodes: [])
        }
    }

    @Test func decodeRejectsInvalidConfiguration() {
        let json = #"{"name":"dev","kubernetesVersion":"","nodes":[{"name":"dev","roles":["worker"]}]}"#
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ClusterConfiguration.self, from: Data(json.utf8))
        }
    }

    @Test func decodeIgnoresUnknownKeysAndDefaultsAbsentOnes() throws {
        let json = #"{"name":"dev","kubernetesVersion":"v1.35.5","futureField":1,"nodes":[{"name":"dev","roles":["worker"],"extra":true}]}"#
        let c = try JSONDecoder().decode(ClusterConfiguration.self, from: Data(json.utf8))
        #expect(c.name == "dev")
        #expect(!c.remove)
        #expect(c.cni == nil)
        #expect(c.nodes[0].kind == .linux)
    }

    @Test func initRejectsGarbageKubernetesVersions() throws {
        let node = try NodeConfiguration(name: "dev", roles: ["control-plane"])
        for version in ["", "v1.35.5\u{1B}[31m", "v1.35\n", "v1 35", "-v1", ":v1", "v1@sha256:" + String(repeating: "a", count: 64), String(repeating: "v", count: 129)] {
            #expect(throws: (any Error).self, "\(version.debugDescription) should be rejected") {
                _ = try ClusterConfiguration(name: "dev", kubernetesVersion: version, nodes: [node])
            }
        }
    }

    @Test func makeRecordsSharedImageStore() throws {
        let c = try ClusterConfiguration.make(
            name: "dev", nodeImage: image, remove: false, sharedImageStore: true, workers: 0, cni: nil, fqdn: nil)
        #expect(c.sharedImageStore)
        let decoded = try JSONDecoder().decode(ClusterConfiguration.self, from: JSONEncoder().encode(c))
        #expect(decoded.sharedImageStore)
    }

    @Test func sharedImageStoreDefaultsToFalse() throws {
        let c = try ClusterConfiguration.make(name: "dev", nodeImage: image, remove: false, workers: 0, cni: nil, fqdn: nil)
        #expect(!c.sharedImageStore)
        let json = #"{"name":"dev","kubernetesVersion":"v1.35.5","nodes":[{"name":"dev","roles":["worker"]}]}"#
        let decoded = try JSONDecoder().decode(ClusterConfiguration.self, from: Data(json.utf8))
        #expect(!decoded.sharedImageStore)
    }
}
