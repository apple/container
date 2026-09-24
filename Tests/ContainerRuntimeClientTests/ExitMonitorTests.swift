//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ContainerRuntimeClient
import Containerization
import Foundation
import Testing

struct ExitMonitorTests {
    @Test
    func trackReleasesEntriesAfterExit() async throws {
        let monitor = ExitMonitor()
        let id = "exec-\(UUID().uuidString)"

        try await monitor.registerProcess(id: id) { _, _ in }
        try await monitor.track(id: id) {
            ExitStatus(exitCode: 0)
        }

        // Allow the monitor task to finish and drop its bookkeeping.
        for _ in 0..<50 {
            do {
                try await monitor.registerProcess(id: id) { _, _ in }
                return
            } catch {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        Issue.record("ExitMonitor did not release tracking for \(id) after exit")
    }

    @Test
    func trackReleasesEntriesAfterWaitHandlerFailure() async throws {
        let monitor = ExitMonitor()
        let id = "exec-fail-\(UUID().uuidString)"

        try await monitor.registerProcess(id: id) { _, status in
            #expect(status.exitCode == -1)
        }
        try await monitor.track(id: id) {
            struct Boom: Error {}
            throw Boom()
        }

        for _ in 0..<50 {
            do {
                try await monitor.registerProcess(id: id) { _, _ in }
                return
            } catch {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        Issue.record("ExitMonitor did not release tracking after WaitHandler failure")
    }

    @Test
    func manyCompletedTracksDoNotBlockReregistration() async throws {
        let monitor = ExitMonitor()

        for i in 0..<200 {
            let id = "batch-\(i)"
            try await monitor.registerProcess(id: id) { _, _ in }
            try await monitor.track(id: id) {
                ExitStatus(exitCode: 0)
            }
        }

        // Give tasks a moment to settle, then confirm IDs can be reused.
        try await Task.sleep(for: .milliseconds(200))
        for i in 0..<200 {
            let id = "batch-\(i)"
            try await monitor.registerProcess(id: id) { _, _ in }
            await monitor.stopTracking(id: id)
        }
    }
}
