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

// MARK: - Fixtures

let fixtureDefaultCPUs: Int = max(ProcessInfo.processInfo.processorCount / 4, 2)
let fixtureDefaultMemoryMiB: UInt64 = {
    let gb = max(Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) / 4, 2)
    return UInt64(gb * 1024)
}()

func makeSnapshot(
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

func makeControlPlane(_ name: String, cpus: Int = fixtureDefaultCPUs, memoryMiB: UInt64 = fixtureDefaultMemoryMiB, addr: String = "") throws -> ContainerSnapshot {
    try makeSnapshot(id: name, role: "control-plane", cpus: cpus, memoryMiB: memoryMiB, addr: addr)
}

func makeWorker(_ id: String, cpus: Int = max(fixtureDefaultCPUs / 2, 1), memoryMiB: UInt64 = max(fixtureDefaultMemoryMiB / 2, 512)) throws -> ContainerSnapshot {
    try makeSnapshot(id: id, role: "worker", cpus: cpus, memoryMiB: memoryMiB)
}

func makeConfig(_ name: String, workers: UInt = 0) -> ClusterConfiguration {
    // Test fixtures are valid by construction.
    var nodes = [
        try! NodeConfiguration(
            name: name, roles: workers == 0 ? ["control-plane", "worker"] : ["control-plane"])
    ]
    if workers > 0 {
        for i in 1...workers {
            nodes.append(try! NodeConfiguration(name: "\(name)-worker-\(i)", roles: ["worker"]))
        }
    }
    return try! ClusterConfiguration(name: name, kubernetesVersion: "v1.35.5", cni: nil, fqdn: nil, nodes: nodes)
}
