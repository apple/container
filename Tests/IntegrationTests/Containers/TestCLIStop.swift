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
import Testing

@Suite
struct TestCLIStop {
    @Test func testStopWithExplicitSignal() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            try await f.withContainer(image: image, autoRemove: false) { name in
                try f.doStop(name, signal: "SIGTERM")
                #expect(try f.getContainerStatus(name) == "stopped")
            }
        }
    }

    @Test func testStopWithoutSignal() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            try await f.withContainer(image: image, autoRemove: false) { name in
                try f.doStop(name, signal: nil)
                #expect(try f.getContainerStatus(name) == "stopped")
            }
        }
    }

    @Test func testStopSignalInInspect() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            try await f.withContainer(image: image, autoRemove: false) { name in
                let inspect = try f.inspectContainer(name)
                // Alpine doesn't set a STOPSIGNAL, so this should be nil.
                #expect(inspect.configuration.stopSignal == nil)
            }
        }
    }

    @Test func testStopIdempotent() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            try await f.withContainer(image: image, autoRemove: false) { name in
                try f.doStop(name, signal: "SIGKILL")
                #expect(try f.getContainerStatus(name) == "stopped")
                // Stopping an already-stopped container should not fail.
                try f.doStop(name, signal: "SIGKILL")
            }
        }
    }
}
