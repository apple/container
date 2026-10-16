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
import Testing

@testable import ContainerCluster

struct ClusterControlPlaneResourceTests {
    @Test func noWorkersLeavesFlagsUnchanged() {
        let r = ClusterHelper.controlPlaneResourceFlags(Flags.Resource(cpus: nil, memory: nil), hasWorkers: false)
        #expect(r.cpus == nil)
        #expect(r.memory == nil)
    }

    @Test func noWorkersKeepsExplicitValues() {
        let r = ClusterHelper.controlPlaneResourceFlags(Flags.Resource(cpus: 6, memory: "12g"), hasWorkers: false)
        #expect(r.cpus == 6)
        #expect(r.memory == "12g")
    }

    @Test func workersGiveFixedControlPlaneDefaults() {
        let r = ClusterHelper.controlPlaneResourceFlags(Flags.Resource(cpus: nil, memory: nil), hasWorkers: true)
        #expect(r.cpus == 2)
        #expect(r.memory == "2g")
    }

    @Test func explicitValuesWinWithWorkers() {
        let r = ClusterHelper.controlPlaneResourceFlags(Flags.Resource(cpus: 4, memory: nil), hasWorkers: true)
        #expect(r.cpus == 4)
        #expect(r.memory == "2g")
    }
}
