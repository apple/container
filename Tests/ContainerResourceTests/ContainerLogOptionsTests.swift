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
    @Test func defaultOptionsPreserveExistingBehavior() {
        let options = ContainerLogOptions.default

        #expect(options.tail == nil)
        #expect(options.since == nil)
        #expect(options.until == nil)
        #expect(!options.timestamps)
        #expect(options.stream == nil)
    }

    @Test func customOptionsRoundTripThroughJSON() throws {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let until = Date(timeIntervalSince1970: 1_900_000_000)
        let options = ContainerLogOptions(
            tail: 100,
            since: since,
            until: until,
            timestamps: true,
            stream: .boot
        )

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(ContainerLogOptions.self, from: data)

        #expect(decoded == options)
    }
}
