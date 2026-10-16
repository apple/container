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

import ArgumentParser
import Testing

@testable import ContainerCluster

struct ClusterWorkerGroupTests {
    @Test func bareNumberIsCount() throws {
        #expect(try WorkerGroup(parsing: "3") == WorkerGroup(count: 3))
    }

    @Test func bareZeroIsAllowed() throws {
        #expect(try WorkerGroup(parsing: "0") == WorkerGroup(count: 0))
    }

    @Test func keyValueGroup() throws {
        #expect(try WorkerGroup(parsing: "count=2,cpus=4,memory=8g") == WorkerGroup(count: 2, cpus: 4, memory: "8g"))
    }

    @Test func countDefaultsToOne() throws {
        #expect(try WorkerGroup(parsing: "cpus=4") == WorkerGroup(count: 1, cpus: 4, memory: nil))
    }

    @Test(arguments: [
        "", "abc", "-1", "count", "count=", "count=x", "count=-1",
        "cpus=0", "cpus=-2", "cpus=x", "memory=0", "memory=x", "memory=9999999999999999999999p",
        "color=red", "count=1,count=2", "count=1,,cpus=2", "count=0,cpus=4", "count=0,memory=4g",
    ])
    func invalidValuesAreRejected(_ value: String) {
        #expect(throws: ValidationError.self) {
            try WorkerGroup(parsing: value)
        }
    }

    @Test func zeroCountWithoutSizingIsAllowed() throws {
        #expect(try WorkerGroup(parsing: "count=0") == WorkerGroup(count: 0))
    }
}
