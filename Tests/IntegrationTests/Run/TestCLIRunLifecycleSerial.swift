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

/// Serial lifecycle tests that require non-warmup images or exclusive port binding.
@Suite(.serialized)
struct TestCLIRunLifecycleSerial {
    @Test func testStartPortBindFails() async throws {
        try await ContainerFixture.with { f in
            let port = UInt16.random(in: 50000..<60000)
            let serverImage = "docker.io/library/python:alpine"
            try f.run(["image", "pull", serverImage]).check()

            let name = "\(f.testID)-c"
            try f.doCreate(name: name, ports: ["\(port)"])
            f.addCleanup { try? f.doRemove(name) }

            let server = "\(f.testID)-server"
            try await f.doLongRun(
                name: server,
                image: serverImage,
                args: ["--publish", "\(port):\(port)"],
                containerArgs: ["python3", "-m", "http.server", "\(port)"])
            f.addCleanup { try? f.doStop(server) }

            let startResult = try f.run(["start", name])
            #expect(startResult.status != 0, "expected start to fail when port is already bound")

            let status = try f.getContainerStatus(name)
            #expect(status == "stopped")
        }
    }
}
