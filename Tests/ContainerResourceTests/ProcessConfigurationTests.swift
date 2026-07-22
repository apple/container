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

struct ProcessConfigurationContainerIDTests {
    @Test func exposesContainerIDWhenAbsent() throws {
        let result = ProcessConfiguration.environmentExposingContainerID(
            ["PATH=/usr/bin"],
            id: "my-container"
        )
        #expect(result.contains("CONTAINER_ID=my-container"))
        #expect(result.contains("PATH=/usr/bin"))
    }

    @Test func preservesUserSuppliedContainerID() throws {
        let result = ProcessConfiguration.environmentExposingContainerID(
            ["CONTAINER_ID=override"],
            id: "my-container"
        )
        #expect(result == ["CONTAINER_ID=override"])
    }

    @Test func addsContainerIDToEmptyEnvironment() throws {
        let result = ProcessConfiguration.environmentExposingContainerID([], id: "abc-123")
        #expect(result == ["CONTAINER_ID=abc-123"])
    }
}
