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

@Suite
struct TestCLIVolumeMountOptions {
    private let alpine = WarmupImage.alpine320.rawValue

    /// The mount line for a destination inside a running container.
    private func mountLine(_ f: ContainerFixture, container: String, destination: String) throws -> String {
        let mounts = try f.doExec(container, cmd: ["cat", "/proc/mounts"])
        guard let line = mounts.split(separator: "\n").first(where: { $0.contains(" \(destination) ") }) else {
            throw CommandError.executionFailed("no mount line for \(destination) in: \(mounts)")
        }
        return String(line)
    }

    @Test func testVolumeMountsWithDiscardByDefault() async throws {
        try await ContainerFixture.with { f in
            let vol = "\(f.testID)-vol"
            let c = "\(f.testID)-c"
            f.addCleanup {
                try? f.doRemoveIfExists(c, force: true, ignoreFailure: true)
                f.doVolumeDeleteIfExists(vol)
            }

            try f.doVolumeCreate(vol)
            try await f.doLongRun(name: c, image: alpine, args: ["-v", "\(vol):/data"], autoRemove: false, waitUntilRunning: true)
            let line = try mountLine(f, container: c, destination: "/data")
            #expect(line.contains("discard"), "an ext4 volume mounts with continuous discard: \(line)")
            try f.doStop(c)
        }
    }

    @Test func testVolumeRecordOptionsRideEveryAttachment() async throws {
        try await ContainerFixture.with { f in
            let vol = "\(f.testID)-vol"
            let c = "\(f.testID)-c"
            f.addCleanup {
                try? f.doRemoveIfExists(c, force: true, ignoreFailure: true)
                f.doVolumeDeleteIfExists(vol)
            }

            try f.run(["volume", "create", "--opt", "o=noatime", vol]).check()
            try await f.doLongRun(name: c, image: alpine, args: ["-v", "\(vol):/data"], autoRemove: false, waitUntilRunning: true)
            let line = try mountLine(f, container: c, destination: "/data")
            #expect(line.contains("noatime"), "the record's o options mount with the volume: \(line)")
            #expect(line.contains("discard"), "the runtime's discard rides regardless of the record: \(line)")
            try f.doStop(c)
        }
    }
}
