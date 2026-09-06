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

@testable import ContainerCommands

struct BuilderStartTests {
    private func resources(cpus: Int, mebibytes: UInt64) -> ContainerConfiguration.Resources {
        var resources = ContainerConfiguration.Resources()
        resources.cpus = cpus
        resources.memoryInBytes = mebibytes * 1024 * 1024
        return resources
    }

    @Test
    func startingWithoutResourceFlagsPreservesExistingResources() {
        let requested = resources(cpus: 2, mebibytes: 2048)
        let existing = resources(cpus: 6, mebibytes: 12288)

        let result = Application.BuilderStart.resourcesForStart(
            requested: requested,
            existing: existing,
            cpus: nil,
            memory: nil
        )

        #expect(result.cpus == 6)
        #expect(result.memoryInBytes == 12288 * 1024 * 1024)
    }

    @Test
    func startingWithCpuFlagPreservesExistingMemory() {
        let requested = resources(cpus: 2, mebibytes: 2048)
        let existing = resources(cpus: 6, mebibytes: 12288)

        let result = Application.BuilderStart.resourcesForStart(
            requested: requested,
            existing: existing,
            cpus: 2,
            memory: nil
        )

        #expect(result.cpus == 2)
        #expect(result.memoryInBytes == 12288 * 1024 * 1024)
    }

    @Test
    func startingWithMemoryFlagPreservesExistingCpus() {
        let requested = resources(cpus: 2, mebibytes: 4096)
        let existing = resources(cpus: 6, mebibytes: 12288)

        let result = Application.BuilderStart.resourcesForStart(
            requested: requested,
            existing: existing,
            cpus: nil,
            memory: "4G"
        )

        #expect(result.cpus == 6)
        #expect(result.memoryInBytes == 4096 * 1024 * 1024)
    }
}
