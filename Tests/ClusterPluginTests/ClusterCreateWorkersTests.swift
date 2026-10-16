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
import Testing

@testable import ContainerCluster

@Suite("ClusterCreate --workers flag")
struct ClusterCreateWorkersFlagTests {
    @Test func defaultsToNoWorkers() throws {
        #expect(try ClusterCreate.parse([]).workers.isEmpty)
    }

    @Test func bareNumber() throws {
        #expect(try ClusterCreate.parse(["--workers", "3"]).workers == [WorkerGroup(count: 3)])
    }

    @Test func repeatedFlagsAreCollectedInOrder() throws {
        let command = try ClusterCreate.parse(["--workers", "count=2,cpus=4,memory=8g", "--workers", "1"])
        #expect(command.workers == [WorkerGroup(count: 2, cpus: 4, memory: "8g"), WorkerGroup(count: 1)])
    }

    @Test func resourceFlagsAreSeparateFromWorkers() throws {
        let command = try ClusterCreate.parse(["--cpus", "4", "--memory", "8g", "--workers", "cpus=2"])
        #expect(command.resourceFlags.cpus == 4)
        #expect(command.resourceFlags.memory == "8g")
        #expect(command.workers == [WorkerGroup(count: 1, cpus: 2, memory: nil)])
    }

    @Test func totalAtLimitIsAccepted() throws {
        _ = try ClusterCreate.parse(["--workers", "\(ClusterConfiguration.maxWorkers)"])
    }

    @Test func totalOverLimitIsRejected() {
        #expect(throws: (any Error).self) {
            try ClusterCreate.parse(["--workers", "\(ClusterConfiguration.maxWorkers + 1)"])
        }
    }

    @Test func totalOverLimitAcrossGroupsIsRejected() {
        #expect(throws: (any Error).self) {
            try ClusterCreate.parse(["--workers", "600", "--workers", "count=600,cpus=2"])
        }
    }

    @Test func hugeCountsDoNotOverflowTheTotal() {
        #expect(throws: (any Error).self) {
            try ClusterCreate.parse(["--workers", "\(UInt.max)", "--workers", "\(UInt.max)"])
        }
    }

    @Test(arguments: ["abc", "cpus=0", "memory=x", "count=0,cpus=4", "color=red"])
    func invalidValueIsRejected(_ value: String) {
        #expect(throws: (any Error).self) {
            try ClusterCreate.parse(["--workers", value])
        }
    }
}
