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

import Foundation
import Testing

/// Serial prune tests — `container prune` affects all stopped containers regardless of name.
@Suite(.serialized)
struct TestCLIPruneCommandSerial {
    @Test(.disabled("flaky — prune picks up containers from concurrent suites; tests being rewritten"))
    func testContainerPruneNoContainers() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["prune"]).check()
            #expect(result.error.contains("Reclaimed Zero KB in disk space"), "should show no containers message")
        }
    }

    @Test func testContainerPruneStoppedContainers() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])

            // One running container that must survive the prune.
            try await f.withContainer(image: image, tag: "running", containerArgs: ["sleep", "3600"]) { npcName in
                // Two containers to stop and prune.
                try await f.withContainer(
                    image: image, tag: "prune0", containerArgs: ["sleep", "3600"], autoRemove: false
                ) { pc0Name in
                    try await f.withContainer(
                        image: image, tag: "prune1", containerArgs: ["sleep", "3600"], autoRemove: false
                    ) { pc1Name in
                        let pc0Id = try f.getContainerId(pc0Name)
                        let pc1Id = try f.getContainerId(pc1Name)

                        try f.doStop(pc0Name)
                        try f.doStop(pc1Name)

                        // Poll until both containers reach stopped state.
                        let deadline = Date().addingTimeInterval(30)
                        while true {
                            let s0 = try f.getContainerStatus(pc0Name)
                            let s1 = try f.getContainerStatus(pc1Name)
                            if s0 == "stopped" && s1 == "stopped" { break }
                            guard Date() < deadline else {
                                throw CommandError.executionFailed(
                                    "Timeout waiting for containers to stop: pc0=\(s0), pc1=\(s1)")
                            }
                            try await Task.sleep(for: .milliseconds(200))
                        }

                        let result = try f.run(["prune"]).check()
                        #expect(
                            result.output.contains(pc0Id) && result.output.contains(pc1Id),
                            "prune output should list stopped container IDs")
                        #expect(
                            !result.error.contains("Reclaimed Zero KB in disk space"),
                            "reclaimed space should not be zero")

                        let npcStatus = try f.getContainerStatus(npcName)
                        #expect(npcStatus == "running", "running container should not be pruned")
                    }
                }
            }
        }
    }
}
