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

import ContainerTestSupport
import Foundation
import Testing

@Suite(.serialized)
struct TestCLIVolumesSerial {
    private let alpine = WarmupImage.alpine320.rawValue

    @Test func testVolumePruneNoVolumes() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["volume", "prune"]).check()
            #expect(result.error.contains("Zero KB"), "should show no space reclaimed")
        }
    }

    @Test func testVolumePruneUnusedVolumes() async throws {
        try await ContainerFixture.with { f in
            let v1 = "\(f.testID)-vol1"
            let v2 = "\(f.testID)-vol2"
            f.addCleanup {
                f.doVolumeDeleteIfExists(v1)
                f.doVolumeDeleteIfExists(v2)
            }

            try f.doVolumeCreate(v1)
            try f.doVolumeCreate(v2)
            let list = try f.run(["volume", "list", "--quiet"]).check().output
            #expect(list.contains(v1) && list.contains(v2))

            let result = try f.run(["volume", "prune", "--all"]).check()
            #expect(result.output.contains(v1))
            #expect(result.output.contains(v2))
            #expect(result.error.contains("Reclaimed"))

            let listAfter = try f.run(["volume", "list", "--quiet"]).check().output
            #expect(!listAfter.contains(v1) && !listAfter.contains(v2))
        }
    }

    @Test func testVolumePruneTakesTheAnonymousAndKeepsTheNamed() async throws {
        try await ContainerFixture.with { f in
            let named = "\(f.testID)-named"
            let c = "\(f.testID)-c1"
            try f.doPull(alpine)
            f.addCleanup {
                try? f.doRemoveIfExists(c, force: true, ignoreFailure: true)
                f.doVolumeDeleteIfExists(named)
            }

            // A container given a mount with no name is given a volume nobody
            // asked for by name, which is the kind a prune is free to take.
            try f.doVolumeCreate(named)
            try await f.doLongRun(name: c, image: alpine, args: ["-v", "/data"], autoRemove: false, waitUntilRunning: true)
            let anonymous = try f.getContainerMountedVolumeNames(c)
            try #require(anonymous.count == 1, "the container should mount exactly one anonymous volume")
            let anon = anonymous[0]
            f.addCleanup { f.doVolumeDeleteIfExists(anon) }

            try f.doStop(c)
            try f.doRemove(c)

            try f.run(["volume", "prune"]).check()
            #expect(!(try f.volumeExists(anon)), "an anonymous volume nothing mounts should be pruned")
            #expect(try f.volumeExists(named), "a named volume should survive a prune that was not asked for all")

            try f.run(["volume", "prune", "--all"]).check()
            #expect(!(try f.volumeExists(named)), "a named volume should be pruned when all of them are asked for")
        }
    }

    @Test func testVolumePruneSkipsVolumeInUse() async throws {
        try await ContainerFixture.with { f in
            let vInUse = "\(f.testID)-inuse"
            let vUnused = "\(f.testID)-unused"
            let c = "\(f.testID)-c1"
            try f.doPull(alpine)
            let image = alpine
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemoveIfExists(c, force: true, ignoreFailure: true)
                f.doVolumeDeleteIfExists(vInUse)
                f.doVolumeDeleteIfExists(vUnused)
            }

            try f.doVolumeCreate(vInUse)
            try f.doVolumeCreate(vUnused)
            try await f.doLongRun(name: c, image: image, args: ["-v", "\(vInUse):/data"], autoRemove: false, waitUntilRunning: true)

            try f.run(["volume", "prune", "--all"]).check()

            let listAfter = try f.run(["volume", "list", "--quiet"]).check().output
            #expect(listAfter.contains(vInUse), "in-use volume should NOT be pruned")
            #expect(!listAfter.contains(vUnused), "unused volume should be pruned")

            try f.doStop(c)
            try? f.doRemoveIfExists(c, force: true, ignoreFailure: true)
            f.doVolumeDeleteIfExists(vInUse)
        }
    }

    @Test func testVolumePruneSkipsVolumeAttachedToStoppedContainer() async throws {
        try await ContainerFixture.with { f in
            let vol = "\(f.testID)-vol"
            let c = "\(f.testID)-c1"
            try f.doPull(alpine)
            let image = alpine
            f.addCleanup {
                try? f.doRemoveIfExists(c, force: true, ignoreFailure: true)
                f.doVolumeDeleteIfExists(vol)
            }

            try f.doVolumeCreate(vol)
            try f.doCreate(name: c, image: image, volumes: ["\(vol):/data"])
            try await Task.sleep(for: .seconds(1))

            try f.run(["volume", "prune", "--all"]).check()
            #expect(try f.volumeExists(vol), "volume attached to stopped container should NOT be pruned")

            try? f.doRemoveIfExists(c, force: true, ignoreFailure: true)
            try f.run(["volume", "prune", "--all"]).check()
            #expect(!(try f.volumeExists(vol)), "volume should be pruned after container is deleted")
        }
    }

}
