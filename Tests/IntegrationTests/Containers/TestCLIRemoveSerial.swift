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

/// Serial removal tests that use `delete --all` and affect global container state.
@Suite(.serialized)
struct TestCLIRemoveSerial {
    @Test func testDeleteAllStopped() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            if try !f.isImagePresent(image) { try f.doPull(image) }
            let name1 = "\(f.testID)-c1"
            let name2 = "\(f.testID)-c2"
            try f.doCreate(name: name1, image: image)
            f.addCleanup { try f.doRemoveIfExists(name1, ignoreFailure: true) }
            try f.doCreate(name: name2, image: image)
            f.addCleanup { try f.doRemoveIfExists(name2, ignoreFailure: true) }

            try f.run(["delete", "--all"]).check()

            #expect(try f.run(["inspect", name1]).status != 0, "name1 should be deleted")
            #expect(try f.run(["inspect", name2]).status != 0, "name2 should be deleted")
        }
    }

    @Test func testDeleteAllSkipsRunning() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            if try !f.isImagePresent(image) { try f.doPull(image) }
            let runningName = "\(f.testID)-running"
            let stoppedName = "\(f.testID)-stopped"

            try await f.doLongRun(name: runningName, image: image, autoRemove: false)
            f.addCleanup {
                try? f.doStop(runningName)
                try? f.doRemove(runningName)
            }
            try f.doCreate(name: stoppedName, image: image)
            f.addCleanup { try f.doRemoveIfExists(stoppedName, ignoreFailure: true) }

            try f.run(["delete", "--all"]).check()

            #expect(try f.getContainerStatus(runningName) == "running", "running container should survive delete --all")
            #expect(try f.run(["inspect", stoppedName]).status != 0, "stopped container should be deleted")
        }
    }

    @Test func testDeleteAllForce() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            if try !f.isImagePresent(image) { try f.doPull(image) }
            let name = "\(f.testID)-c"
            try await f.doLongRun(name: name, image: image, autoRemove: false)
            f.addCleanup { try f.doRemoveIfExists(name, force: true, ignoreFailure: true) }

            try f.run(["delete", "--all", "--force"]).check()

            #expect(try f.run(["inspect", name]).status != 0, "container should be deleted by --force")
        }
    }
}
