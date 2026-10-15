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

@testable import ContainerResource

struct ContainerLogOptionsTests {

    @Test("Default log options preserve existing logs behavior")
    func testDefaultOptions() {
        let options = ContainerLogOptions.default

        #expect(options.since == nil)
        #expect(!options.timestamps)
    }

    @Test("Custom log options round-trip through JSON")
    func testCustomOptionsRoundTrip() throws {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let options = ContainerLogOptions(since: since, timestamps: true)

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(ContainerLogOptions.self, from: data)

        #expect(decoded.since == since)
        #expect(decoded.timestamps)
    }
}
