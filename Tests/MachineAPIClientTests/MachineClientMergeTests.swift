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

@testable import MachineAPIClient

struct MachineClientMergeTests {
    @Test func mergeAppliesSetupScriptToResources() throws {
        let resources = MachineResources(schemaVersion: 1, shell: "/bin/sh")
        let merged = MachineClient.merge(resources: resources, setupScript: "echo hello")
        #expect(merged?.setupScript == "echo hello")
        #expect(merged?.shell == "/bin/sh")
    }

    @Test func mergeLeavesResourcesUnchangedWhenNoSetupScript() throws {
        let resources = MachineResources(schemaVersion: 1, setupScript: "existing")
        let merged = MachineClient.merge(resources: resources, setupScript: nil)
        #expect(merged?.setupScript == "existing")
    }

    @Test func mergeReturnsNilWhenNoResources() throws {
        let merged = MachineClient.merge(resources: nil, setupScript: "echo hello")
        #expect(merged == nil)
    }
}
