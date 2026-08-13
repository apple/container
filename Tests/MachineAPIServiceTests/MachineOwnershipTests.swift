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

import ContainerResource
import Testing

@testable import MachineAPIService

struct MachineOwnershipTests {
    @Test
    func identifiesLegacyBackingContainer() {
        #expect(
            MachinesService.isLegacyBackingContainer(
                id: "legacy-ab12cd",
                labels: [
                    ResourceLabelKeys.plugin: "machine",
                    ResourceLabelKeys.machineID: "legacy",
                ],
                machineID: "legacy"
            )
        )
    }

    @Test
    func rejectsUnrelatedContainer() {
        #expect(
            !MachinesService.isLegacyBackingContainer(
                id: "legacy-ab12cd",
                labels: [
                    ResourceLabelKeys.plugin: "machine",
                    ResourceLabelKeys.machineID: "other",
                ],
                machineID: "legacy"
            )
        )
        #expect(
            !MachinesService.isLegacyBackingContainer(
                id: "legacy-ab12cd",
                labels: [ResourceLabelKeys.machineID: "legacy"],
                machineID: "legacy"
            )
        )
    }
}
