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

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerK8s

private func host(_ port: UInt16, _ proto: PublishProtocol = .tcp) -> K8sHelper.HostPort {
    K8sHelper.HostPort(port: port, proto: proto)
}

private func makeSnapshot(
    _ id: String,
    publishing specs: [String],
    status: RuntimeStatus = .running,
    isCluster: Bool = true
) throws -> ContainerSnapshot {
    let ports = try Parser.publishPorts(specs)
    let portsJSON = String(data: try JSONEncoder().encode(ports), encoding: .utf8) ?? "[]"
    let labelsJSON = isCluster ? #"{"com.apple.container.plugin":"k8s"}"# : "{}"
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
                "resources": {"cpus":2,"memoryInBytes":2147483648},
                "publishedPorts": \(portsJSON),
                "labels": \(labelsJSON)
            },
            "status": "\(status.rawValue)",
            "networks": []
        }
        """
    return try JSONDecoder().decode(ContainerSnapshot.self, from: Data(json.utf8))
}

private func claim(
    _ container: String,
    _ containerPort: UInt16,
    status: RuntimeStatus = .running,
    isCluster: Bool = true
) -> K8sHelper.HostPortClaim {
    K8sHelper.HostPortClaim(container: container, containerPort: containerPort, status: status, isCluster: isCluster)
}

struct K8sPublishPortsTests {
    @Test
    func publishSpecUsesRuntimeParser() throws {
        let port = try Parser.publishPort("127.0.0.1:8443:30443/udp")
        #expect(port.hostPort == 8443)
        #expect(port.containerPort == 30443)
        #expect(port.proto == .udp)
        #expect(port.hostAddress.description == "127.0.0.1")
    }

    @Test
    func invalidPublishSpecThrows() {
        #expect(throws: ContainerizationError.self) {
            _ = try Parser.publishPorts(["nonsense"])
        }
    }

    @Test
    func hostPortsExpandsRanges() throws {
        let ports = try Parser.publishPorts(["8080:30080", "9000-9002:31000-31002/tcp"])
        #expect(K8sHelper.hostPorts(of: ports) == [host(8080), host(9000), host(9001), host(9002)])
    }

    @Test
    func hostPortsOfNothingIsEmpty() {
        #expect(K8sHelper.hostPorts(of: []) == [])
    }

    @Test
    func hostPortsSeparateProtocols() throws {
        let ports = try Parser.publishPorts(["8125:30125/udp"])
        #expect(K8sHelper.hostPorts(of: ports) == [host(8125, .udp)])
    }

    @Test
    func claimsNameTheHoldingContainerAndItsTargetPort() throws {
        let claims = K8sHelper.claims(of: [try makeSnapshot("dev", publishing: ["6445:6443", "8080:30080"])])
        #expect(claims[host(6445)]?.container == "dev")
        #expect(claims[host(6445)]?.containerPort == 6443)
        #expect(claims[host(6445)]?.isCluster == true)
        #expect(claims[host(8080)]?.containerPort == 30080)
        #expect(claims[host(8081)] == nil)
    }

    @Test
    func claimsWalkRangesPortByPort() throws {
        let claims = K8sHelper.claims(of: [try makeSnapshot("dev", publishing: ["9000-9002:31000-31002"])])
        #expect(claims[host(9001)]?.containerPort == 31001)
        #expect(claims[host(9002)]?.containerPort == 31002)
    }

    @Test
    func claimsCoverPlainContainersToo() throws {
        let claims = K8sHelper.claims(of: [try makeSnapshot("nginx", publishing: ["8080:80"], isCluster: false)])
        #expect(claims[host(8080)]?.isCluster == false)
    }

    @Test
    func claimsCarryContainerStatus() throws {
        let claims = K8sHelper.claims(of: [try makeSnapshot("dev", publishing: ["8080:30080"], status: .stopped)])
        #expect(claims[host(8080)]?.isLive == false)
    }

    @Test
    func aLiveClaimOutranksAStoppedOneOnTheSamePort() throws {
        let snapshots = [
            try makeSnapshot("stopped-one", publishing: ["8080:30080"], status: .stopped),
            try makeSnapshot("running-one", publishing: ["8080:30081"]),
        ]
        #expect(K8sHelper.claims(of: snapshots)[host(8080)]?.container == "running-one")
        #expect(K8sHelper.claims(of: snapshots.reversed())[host(8080)]?.container == "running-one")
    }

    @Test
    func reservedHostPortClashThrows() {
        let reserved = [host(6445): claim("dev", 6443)]
        #expect(throws: ContainerizationError.self) {
            try K8sHelper.ensureHostPortsAvailable([host(6445), host(8080)], reserved: reserved)
        }
    }

    @Test
    func apiServerClashNamesTheHoldingCluster() {
        let reserved = [host(6445): claim("dev", 6443)]
        let error = #expect(throws: ContainerizationError.self) {
            try K8sHelper.ensureHostPortsAvailable([host(6445)], reserved: reserved)
        }
        #expect(error?.message.contains("host port 6445/tcp") == true)
        #expect(error?.message.contains("running k8s cluster 'dev' for its Kubernetes API server") == true)
    }

    @Test
    func nodePortClashNamesTheForwardedPort() {
        let reserved = [host(8080): claim("dev", 30080)]
        let error = #expect(throws: ContainerizationError.self) {
            try K8sHelper.ensureHostPortsAvailable([host(8080)], reserved: reserved)
        }
        #expect(error?.message.contains("running k8s cluster 'dev' (-> 30080)") == true)
    }

    @Test
    func plainContainerClashIsNotCalledACluster() {
        let reserved = [host(8080): claim("nginx", 80, isCluster: false)]
        let error = #expect(throws: ContainerizationError.self) {
            try K8sHelper.ensureHostPortsAvailable([host(8080)], reserved: reserved)
        }
        #expect(error?.message.contains("running container 'nginx' (-> 80)") == true)
    }

    @Test
    func stoppedHolderWarnsInsteadOfFailing() throws {
        let reserved = [host(8080): claim("nginx", 80, status: .stopped, isCluster: false)]
        let warnings = try K8sHelper.ensureHostPortsAvailable([host(8080)], reserved: reserved)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("stopped container 'nginx' (-> 80)") == true)
    }

    @Test
    func stoppingHolderStillFails() {
        let reserved = [host(8080): claim("dev", 30080, status: .stopping)]
        #expect(throws: ContainerizationError.self) {
            try K8sHelper.ensureHostPortsAvailable([host(8080)], reserved: reserved)
        }
    }

    @Test
    func aLiveClashOutweighsAStoppedOneRegardlessOfPortOrder() {
        let reserved = [
            host(6445): claim("stopped-one", 6443, status: .stopped),
            host(8080): claim("running-one", 30080),
        ]
        let error = #expect(throws: ContainerizationError.self) {
            try K8sHelper.ensureHostPortsAvailable([host(6445), host(8080)], reserved: reserved)
        }
        #expect(error?.message.contains("host port 8080/tcp") == true)
    }

    @Test
    func clashReportsTheLowestCollidingPort() {
        let reserved = [
            host(6445): claim("dev", 6443),
            host(8080): claim("dev", 30080),
        ]
        let error = #expect(throws: ContainerizationError.self) {
            try K8sHelper.ensureHostPortsAvailable([host(8080), host(6445)], reserved: reserved)
        }
        #expect(error?.message.contains("host port 6445/tcp") == true)
    }

    @Test
    func sameHostPortOnAnotherProtocolIsAvailable() throws {
        let reserved = [host(8125, .udp): claim("dev", 30125)]
        #expect(try K8sHelper.ensureHostPortsAvailable([host(8125)], reserved: reserved).isEmpty)
    }

    @Test
    func disjointHostPortsAreAvailable() throws {
        let reserved = [host(6445): claim("dev", 6443)]
        #expect(try K8sHelper.ensureHostPortsAvailable([host(8080), host(8443)], reserved: reserved).isEmpty)
    }

    @Test
    func clusterPortSkipsReservedPorts() throws {
        let spec = try K8sHelper.clusterPort(excluding: [])
        let port = try Parser.publishPort(spec)
        #expect(port.containerPort == 6443)

        let bumped = try K8sHelper.clusterPort(excluding: [host(port.hostPort)])
        let bumpedPort = try Parser.publishPort(bumped)
        #expect(bumpedPort.hostPort != port.hostPort)
        #expect(bumpedPort.containerPort == 6443)
    }

    @Test
    func clusterPortIgnoresUDPClaims() throws {
        let spec = try K8sHelper.clusterPort(excluding: [])
        let port = try Parser.publishPort(spec)
        let unchanged = try K8sHelper.clusterPort(excluding: [host(port.hostPort, .udp)])
        #expect(try Parser.publishPort(unchanged).hostPort == port.hostPort)
    }
}

struct K8sPublishPortRenderingTests {
    @Test
    func plainTCPPublishRendersBare() throws {
        #expect(K8sHelper.renderPublishPort(try Parser.publishPort("8080:30080")) == "8080->30080")
    }

    @Test
    func udpPublishCarriesItsProtocol() throws {
        #expect(K8sHelper.renderPublishPort(try Parser.publishPort("8125:30125/udp")) == "8125->30125/udp")
    }

    @Test
    func boundHostAddressIsShown() throws {
        #expect(K8sHelper.renderPublishPort(try Parser.publishPort("127.0.0.1:8080:30080")) == "127.0.0.1:8080->30080")
    }

    @Test
    func ipv6HostAddressIsBracketed() throws {
        #expect(K8sHelper.renderPublishPort(try Parser.publishPort("[::1]:8080:30080")) == "[::1]:8080->30080")
    }

    @Test
    func rangesRenderAsRanges() throws {
        #expect(K8sHelper.renderPublishPort(try Parser.publishPort("9000-9002:31000-31002")) == "9000-9002->31000-31002")
    }
}
