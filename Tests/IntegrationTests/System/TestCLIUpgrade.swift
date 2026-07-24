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

/// Tests for `container upgrade`. Only the running-service guard is exercised:
/// the integration environment always has container services running, and
/// actually installing a package would modify the host.
@Suite
struct TestCLIUpgrade {
    @Test func refusesToRunWhileServicesAreRunning() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["upgrade"])
            #expect(result.status == 1, "upgrade should refuse while services run, stdout: \(result.output)")
            #expect(
                result.error.contains("container system stop"),
                "error should direct the user to stop services, stderr: \(result.error)")
        }
    }
}
