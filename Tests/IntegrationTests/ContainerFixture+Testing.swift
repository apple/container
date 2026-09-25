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

extension ContainerFixture {
    /// Opens a fixture scope using Swift Testing's current test identity.
    ///
    /// `ContainerTestSupport` cannot import Testing, so this test-target wrapper
    /// reads `Test.current` / `Test.Case.current` and forwards them.
    @discardableResult
    static func with<T>(_ body: (ContainerFixture) async throws -> T) async throws -> T {
        try await with(
            identity: TestIdentity(
                name: Test.current?.name,
                identifier: Test.current.map { "\($0.id)" },
                isParameterized: Test.Case.current?.isParameterized ?? false
            ),
            body
        )
    }
}
