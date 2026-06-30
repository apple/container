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

@Suite
struct TestCLIVolumes {
    private let alpine = ContainerFixture.warmupImages[0]

    @Test func testVolumeDataPersistenceAcrossContainers() async throws {
        try await ContainerFixture.with { f in
            let vol = "\(f.testID)-vol"
            let c1 = "\(f.testID)-c1"
            let c2 = "\(f.testID)-c2"
            try f.doPull(alpine)
            let image = try f.copyWarmupImage(alpine)
            f.addCleanup {
                f.doVolumeDeleteIfExists(vol)
                try? f.doRemoveIfExists(c1, force: true, ignoreFailure: true)
                try? f.doRemoveIfExists(c2, force: true, ignoreFailure: true)
            }

            try f.doVolumeCreate(vol)
            try f.doLongRun(name: c1, image: image, args: ["-v", "\(vol):/data"], autoRemove: false)
            try f.waitForContainerRunning(c1)
            _ = try f.doExec(c1, cmd: ["sh", "-c", "echo 'persistent-data-test' > /data/test.txt"])
            try f.doStop(c1)
            try f.doRemove(c1)
            try f.doLongRun(name: c2, image: image, args: ["-v", "\(vol):/data"], autoRemove: false)
            try f.waitForContainerRunning(c2)
            let output = try f.doExec(c2, cmd: ["cat", "/data/test.txt"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == "persistent-data-test")
            try f.doStop(c2)
            try f.doRemove(c2)
            try f.doVolumeDelete(vol)
        }
    }

    @Test func testVolumeSharedAccessConflict() async throws {
        try await ContainerFixture.with { f in
            let vol = "\(f.testID)-vol"
            let c1 = "\(f.testID)-c1"
            let c2 = "\(f.testID)-c2"
            try f.doPull(alpine)
            let image = try f.copyWarmupImage(alpine)
            f.addCleanup {
                try? f.doStop(c1)
                try? f.doRemoveIfExists(c1, force: true, ignoreFailure: true)
                try? f.doRemoveIfExists(c2, force: true, ignoreFailure: true)
                f.doVolumeDeleteIfExists(vol)
            }

            try f.doVolumeCreate(vol)
            try f.doLongRun(name: c1, image: image, args: ["-v", "\(vol):/data"], autoRemove: false)
            try f.waitForContainerRunning(c1)

            let result = try f.run(["run", "--name", c2, "-v", "\(vol):/data", image, "sleep", "infinity"])
            #expect(result.status != 0, "second container should fail when volume is already in use")

            try f.doStop(c1)
            try? f.doRemoveIfExists(c1, force: true, ignoreFailure: true)
            f.doVolumeDeleteIfExists(vol)
        }
    }

    @Test func testVolumeDeleteProtectionWhileInUse() async throws {
        try await ContainerFixture.with { f in
            let vol = "\(f.testID)-vol"
            let c = "\(f.testID)-c1"
            try f.doPull(alpine)
            let image = try f.copyWarmupImage(alpine)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemoveIfExists(c, force: true, ignoreFailure: true)
                f.doVolumeDeleteIfExists(vol)
            }

            try f.doVolumeCreate(vol)
            try f.doLongRun(name: c, image: image, args: ["-v", "\(vol):/data"], autoRemove: false)
            try f.waitForContainerRunning(c)

            #expect(try f.doesVolumeDeleteFail(vol), "volume delete should fail while in use")

            try f.doStop(c)
            try? f.doRemoveIfExists(c, force: true, ignoreFailure: true)
            try f.doVolumeDelete(vol)
        }
    }

    @Test func testVolumeDeleteProtectionWithCreatedContainer() async throws {
        try await ContainerFixture.with { f in
            let vol = "\(f.testID)-vol"
            let c = "\(f.testID)-c1"
            try f.doPull(alpine)
            let image = try f.copyWarmupImage(alpine)
            f.addCleanup {
                try? f.doRemoveIfExists(c, force: true, ignoreFailure: true)
                f.doVolumeDeleteIfExists(vol)
            }

            try f.doVolumeCreate(vol)
            try f.doCreate(name: c, image: image, volumes: ["\(vol):/mnt/data"])
            try await Task.sleep(for: .seconds(1))

            #expect(try f.doesVolumeDeleteFail(vol), "volume delete should fail when used by created container")

            try? f.doRemoveIfExists(c, force: true, ignoreFailure: true)
            f.doVolumeDeleteIfExists(vol)
        }
    }

    @Test func testVolumeBasicOperations() async throws {
        try await ContainerFixture.with { f in
            let vol = "\(f.testID)-vol"
            f.addCleanup { f.doVolumeDeleteIfExists(vol) }

            try f.doVolumeCreate(vol)

            let listResult = try f.run(["volume", "list", "--quiet"]).check()
            let volumes = listResult.output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            #expect(volumes.contains(vol), "created volume should appear in list")

            let inspectResult = try f.run(["volume", "inspect", vol]).check()
            #expect(inspectResult.output.contains(vol))
            #expect(inspectResult.output.contains("\"creationDate\""))
            #expect(!inspectResult.output.contains("\"createdAt\""))

            try f.doVolumeDelete(vol)
        }
    }

    @Test func testImplicitNamedVolumeCreation() async throws {
        try await ContainerFixture.with { f in
            let c = "\(f.testID)-c1"
            let vol = "\(f.testID)-autovolume"
            try f.doPull(alpine)
            let image = try f.copyWarmupImage(alpine)
            f.addCleanup {
                try? f.doRemoveIfExists(c, force: true, ignoreFailure: true)
                f.doVolumeDeleteIfExists(vol)
            }

            #expect(!(try f.volumeExists(vol)), "volume should not exist initially")

            let result = try f.run(["run", "--name", c, "-v", "\(vol):/data", image, "echo", "test"])
            #expect(result.status == 0, "should succeed and auto-create named volume")
            #expect(result.output.contains("test"))
            #expect(try f.volumeExists(vol), "volume should be created")
        }
    }

    @Test func testImplicitNamedVolumeReuse() async throws {
        try await ContainerFixture.with { f in
            let c1 = "\(f.testID)-c1"
            let c2 = "\(f.testID)-c2"
            let vol = "\(f.testID)-sharedvolume"
            try f.doPull(alpine)
            let image = try f.copyWarmupImage(alpine)
            f.addCleanup {
                try? f.doRemoveIfExists(c1, force: true, ignoreFailure: true)
                try? f.doRemoveIfExists(c2, force: true, ignoreFailure: true)
                f.doVolumeDeleteIfExists(vol)
            }

            let r1 = try f.run(["run", "--name", c1, "-v", "\(vol):/data", image, "sh", "-c", "echo 'first' > /data/test.txt"])
            #expect(r1.status == 0)
            let r2 = try f.run(["run", "--name", c2, "-v", "\(vol):/data", image, "cat", "/data/test.txt"])
            #expect(r2.status == 0)
        }
    }

    @Test func testVolumeDeleteNoArgs() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["volume", "delete"])
            #expect(result.status != 0)
        }
    }

    @Test func testVolumeDeleteExplicitNamesConflictWithAll() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["volume", "delete", "--all", "some-volume"])
            #expect(result.status != 0)
            #expect(result.error.contains("conflict"))
        }
    }

    @Test func testVolumeInspectMissingFails() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["volume", "inspect", "definitely-missing-volume"])
            #expect(result.status != 0)
            #expect(result.error.contains("volume not found"))
        }
    }

    @Test func testVolumeCreateWithJournalOrdered() async throws {
        try await ContainerFixture.with { f in
            let vol = "\(f.testID)-vol"
            f.addCleanup { f.doVolumeDeleteIfExists(vol) }
            try f.doVolumeCreate(vol, opts: ["journal=ordered"])
            #expect(try f.volumeExists(vol))
        }
    }

    @Test func testVolumeCreateWithJournalAndSize() async throws {
        try await ContainerFixture.with { f in
            let vol = "\(f.testID)-vol"
            f.addCleanup { f.doVolumeDeleteIfExists(vol) }
            try f.doVolumeCreate(vol, opts: ["journal=writeback:64m"])
        }
    }

    @Test func testVolumeCreateWithInvalidJournalModeErrors() async throws {
        try await ContainerFixture.with { f in
            let vol = "\(f.testID)-vol"
            f.addCleanup { f.doVolumeDeleteIfExists(vol) }
            let result = try f.run(["volume", "create", "--opt", "journal=none", vol])
            #expect(result.status != 0)
        }
    }

    @Test func testJournaledVolumeDataPersistence() async throws {
        try await ContainerFixture.with { f in
            let vol = "\(f.testID)-vol"
            let c1 = "\(f.testID)-c1"
            let c2 = "\(f.testID)-c2"
            try f.doPull(alpine)
            let image = try f.copyWarmupImage(alpine)
            f.addCleanup {
                try? f.doStop(c1)
                try? f.doRemoveIfExists(c1, force: true, ignoreFailure: true)
                try? f.doStop(c2)
                try? f.doRemoveIfExists(c2, force: true, ignoreFailure: true)
                f.doVolumeDeleteIfExists(vol)
            }

            try f.doVolumeCreate(vol, opts: ["journal=ordered"])
            try f.doLongRun(name: c1, image: image, args: ["-v", "\(vol):/data"], autoRemove: false)
            try f.waitForContainerRunning(c1)
            _ = try f.doExec(c1, cmd: ["sh", "-c", "echo 'journaled-data' > /data/test.txt"])
            try f.doStop(c1)
            try f.doRemove(c1)
            try f.doLongRun(name: c2, image: image, args: ["-v", "\(vol):/data"], autoRemove: false)
            try f.waitForContainerRunning(c2)
            let output = try f.doExec(c2, cmd: ["cat", "/data/test.txt"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == "journaled-data")
            try f.doStop(c2)
            try f.doRemove(c2)
            try f.doVolumeDelete(vol)
        }
    }
}
