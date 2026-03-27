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

@testable import ContainerResource

struct ResourceLabelsTest {
    @Test func testValidationGoodLabels() throws {
        let allLabels: [[String: String]] = [
            ["com.example.my-label": "bar"],
            ["mycompany.com/my-label": "bar"],
            ["foo": String(repeating: "0", count: 4096 - "foo".count - "=".count)],
            [String(repeating: "0", count: 128): ""],
        ]
        for labels in allLabels {
            _ = try ResourceLabels(labels)
        }
    }

    @Test func testValidationBadLabels() throws {
        let allLabels: [[String: String]] = [
            [String(repeating: "0", count: 129): ""],
            ["foo": String(repeating: "0", count: 4097 - "foo".count - "=".count)],
            ["com..example.my-label": "bar"],
            ["mycompany.com//my-label": "bar"],
            ["": String(repeating: "0", count: 4096 - "foo".count - "=".count)],
        ]
        for labels in allLabels {
            #expect {
                _ = try ResourceLabels(labels)
            } throws: { error in
                error is ResourceLabels.LabelError
            }
        }
    }
}
