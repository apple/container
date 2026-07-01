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

/// Concurrent removal tests — all use testID-scoped names.
@Suite
struct TestCLIRemove {
    @Test func testDeleteStopped() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            let name = "\(f.testID)-c"
            // create without --rm so the container persists after being stopped
            try f.doCreate(name: name, image: image)
            try f.doRemove(name)
            let result = try f.run(["inspect", name])
            #expect(result.status != 0, "container should not exist after delete")
        }
    }

    @Test func testDeleteAlias() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            let name = "\(f.testID)-c"
            try f.doCreate(name: name, image: image)
            try f.run(["rm", name]).check("rm alias failed")
            let result = try f.run(["inspect", name])
            #expect(result.status != 0, "container should not exist after rm")
        }
    }

    @Test func testDeleteForceRunning() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image) { name in
                try f.doRemove(name, force: true)
                let result = try f.run(["inspect", name])
                #expect(result.status != 0, "container should not exist after force delete")
            }
        }
    }

    @Test func testDeleteNoArgs() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["delete"])
            #expect(result.status != 0, "delete with no args should fail")
        }
    }

    @Test func testDeleteExplicitIdsConflictWithAll() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["delete", "--all", "some-container"])
            #expect(result.status != 0, "delete --all with explicit ID should fail")
            #expect(result.error.contains("conflict"))
        }
    }

    @Test func testDeleteDuplicateIds() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            let name = "\(f.testID)-c"
            try f.doCreate(name: name, image: image)
            f.addCleanup { try f.doRemoveIfExists(name, force: true, ignoreFailure: true) }
            let result = try f.run(["delete", name, name])
            #expect(result.status == 0, "delete with duplicate IDs should succeed, stderr: \(result.error)")
            let lines = result.output.split(separator: "\n").filter { $0.contains(name) }
            #expect(lines.count == 1, "container should be deleted exactly once, got \(lines.count) lines")
        }
    }

    @Test func testInspectMissingContainerFails() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["inspect", "definitely-missing-container"])
            #expect(result.status != 0, "inspect of missing container should fail")
            #expect(result.error.contains("container not found"))
        }
    }
}
