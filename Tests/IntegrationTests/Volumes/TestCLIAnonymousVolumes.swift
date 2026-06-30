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

/// Tests for anonymous (UUID-named) volumes.
///
/// Each test discovers its volumes via container inspect rather than counting
/// global volume state, so the suite runs in the concurrent pass.
@Suite
struct TestCLIAnonymousVolumes {
    private let alpine = ContainerFixture.warmupImages[0]

    @Test func testAnonymousVolumeCreationAndPersistence() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["-v", "/data"], autoRemove: false)
            try f.waitForContainerRunning(c)

            let volumeIDs = try f.getContainerMountedVolumeNames(c)
            try #require(volumeIDs.count == 1, "should have exactly one anonymous volume")
            let volumeID = volumeIDs[0]
            f.addCleanup { f.doVolumeDeleteIfExists(volumeID) }

            try f.doStop(c)
            try f.doRemove(c)
            #expect(try f.volumeExists(volumeID), "anonymous volume should persist after container removal")
        }
    }

    @Test func testAnonymousVolumePersistenceWithoutRm() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c1"
            try f.doLongRun(name: c, image: image, args: ["-v", "/data"], autoRemove: false)
            try f.waitForContainerRunning(c)
            _ = try f.doExec(c, cmd: ["sh", "-c", "echo 'persistent-data' > /data/test.txt"])

            let volumeIDs = try f.getContainerMountedVolumeNames(c)
            try #require(volumeIDs.count == 1)
            let volumeID = volumeIDs[0]
            f.addCleanup { f.doVolumeDeleteIfExists(volumeID) }

            try f.doStop(c)
            try f.doRemove(c)
            #expect(try f.volumeExists(volumeID), "anonymous volume should persist without --rm")

            let c2 = "\(f.testID)-c2"
            try f.doLongRun(name: c2, image: image, args: ["-v", "\(volumeID):/data"], autoRemove: false)
            try f.waitForContainerRunning(c2)
            let output = try f.doExec(c2, cmd: ["cat", "/data/test.txt"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == "persistent-data")
            try f.doStop(c2)
            try f.doRemove(c2)
        }
    }

    @Test func testMultipleAnonymousVolumes() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c, image: image,
                args: ["-v", "/data1", "-v", "/data2", "-v", "/data3"], autoRemove: false)
            try f.waitForContainerRunning(c)

            let volumeIDs = try f.getContainerMountedVolumeNames(c)
            #expect(volumeIDs.count == 3, "should have 3 anonymous volumes")
            f.addCleanup { for v in volumeIDs { f.doVolumeDeleteIfExists(v) } }

            try f.doStop(c)
            try f.doRemove(c)
            for v in volumeIDs { #expect(try f.volumeExists(v), "volume \(v) should persist") }
        }
    }

    @Test func testAnonymousMountSyntax() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c, image: image,
                args: ["--mount", "type=volume,dst=/mydata"], autoRemove: false)
            try f.waitForContainerRunning(c)

            let volumeIDs = try f.getContainerMountedVolumeNames(c)
            #expect(volumeIDs.count == 1, "should have one anonymous volume from --mount syntax")
            f.addCleanup { for v in volumeIDs { f.doVolumeDeleteIfExists(v) } }
            try f.doStop(c)
            try f.doRemove(c)
            #expect(try f.volumeExists(volumeIDs[0]))
        }
    }

    @Test func testAnonymousVolumeUUIDFormat() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["-v", "/data"], autoRemove: false)
            try f.waitForContainerRunning(c)

            // Capture volume IDs before any stop/remove so cleanup and assert can use them.
            let volumeIDs = try f.getContainerMountedVolumeNames(c)
            try #require(volumeIDs.count == 1)
            let volumeID = volumeIDs[0]
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
                f.doVolumeDeleteIfExists(volumeID)
            }

            #expect(volumeID.count == 36, "volume name should be 36 characters (UUID format)")
        }
    }

    @Test func testAnonymousVolumeMetadata() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["-v", "/data"], autoRemove: false)
            try f.waitForContainerRunning(c)

            // Capture volume ID before stop/remove.
            let volumeIDs = try f.getContainerMountedVolumeNames(c)
            try #require(volumeIDs.count == 1)
            let volumeID = volumeIDs[0]
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
                f.doVolumeDeleteIfExists(volumeID)
            }

            let result = try f.run(["volume", "list", "--format", "json"]).check()
            #expect(result.output.contains("\"creationDate\""))
            #expect(!result.output.contains("\"createdAt\""))

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let volumes = try decoder.decode([VolumeResource].self, from: result.outputData)
            let anonVolume = volumes.first { $0.name == volumeID }
            try #require(anonVolume != nil, "should find anonymous volume in list")
            #expect(anonVolume!.isAnonymous == true)
        }
    }

    @Test func testAnonymousVolumeListDisplay() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let namedVol = "\(f.testID)-namedvol"
            let c = "\(f.testID)-c"
            try f.doVolumeCreate(namedVol)
            f.addCleanup { f.doVolumeDeleteIfExists(namedVol) }

            try f.doLongRun(name: c, image: image, args: ["-v", "/data"], autoRemove: false)
            try f.waitForContainerRunning(c)

            // Capture volume IDs while container is running.
            let volumeIDs = try f.getContainerMountedVolumeNames(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
                for v in volumeIDs { f.doVolumeDeleteIfExists(v) }
            }

            let result = try f.run(["volume", "list"]).check()
            #expect(result.output.contains("TYPE"))
            #expect(result.output.contains("named"))
            #expect(result.output.contains("anonymous"))
            #expect(result.output.contains(namedVol))
        }
    }

    @Test func testAnonymousVolumeMixedWithNamedVolume() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let namedVol = "\(f.testID)-namedvol"
            let c = "\(f.testID)-c"
            try f.doVolumeCreate(namedVol)
            f.addCleanup { f.doVolumeDeleteIfExists(namedVol) }

            try f.doLongRun(
                name: c, image: image,
                args: ["-v", "\(namedVol):/named", "-v", "/anon"], autoRemove: false)
            try f.waitForContainerRunning(c)

            let allVolumeIDs = try f.getContainerMountedVolumeNames(c)
            let anonVols = allVolumeIDs.filter { $0 != namedVol }
            #expect(anonVols.count == 1, "should have one anonymous volume")
            f.addCleanup { for v in anonVols { f.doVolumeDeleteIfExists(v) } }

            try f.doStop(c)
            try f.doRemove(c)
            #expect(try f.volumeExists(namedVol), "named volume should persist")
            #expect(try f.volumeExists(anonVols[0]), "anonymous volume should persist")
        }
    }

    @Test func testAnonymousVolumeManualDeletion() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["-v", "/data"], autoRemove: false)
            try f.waitForContainerRunning(c)

            let volumeIDs = try f.getContainerMountedVolumeNames(c)
            try #require(volumeIDs.count == 1)
            let volumeID = volumeIDs[0]

            try f.doStop(c)
            try f.doRemove(c)
            let result = try f.run(["volume", "rm", volumeID])
            #expect(result.status == 0, "manual deletion of unmounted anonymous volume should succeed")
            #expect(!(try f.volumeExists(volumeID)))
        }
    }

    @Test func testAnonymousVolumeDetachedMode() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["-v", "/data"], autoRemove: false)
            try f.waitForContainerRunning(c)

            let volumeIDs = try f.getContainerMountedVolumeNames(c)
            try #require(volumeIDs.count == 1)
            let volumeID = volumeIDs[0]
            f.addCleanup { f.doVolumeDeleteIfExists(volumeID) }

            try f.doStop(c)
            try f.doRemove(c)
            #expect(try f.volumeExists(volumeID), "anonymous volume should persist after container removal")
        }
    }
}
