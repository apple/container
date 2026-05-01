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

import Testing

/// Integration test suites share mutable system state (apiserver, containers, networks, volumes).
/// Running multiple suites concurrently causes resource conflicts and flaky failures.
/// This trait gates suite execution so only one suite runs at a time, while tests within
/// each suite still run in parallel.
struct SerialSuiteTrait: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await SuiteGate.shared.enter()
        do {
            try await function()
        } catch {
            await SuiteGate.shared.leave()
            throw error
        }
        await SuiteGate.shared.leave()
    }
}

extension Trait where Self == SerialSuiteTrait {
    static var serialSuites: Self { Self() }
}
