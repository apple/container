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

import ContainerSandboxService
import Testing

struct DynamicEnvMergeTests {
    @Test
    func testDynamicEnvMergeAddsMissingKey() {
        let overrides = ["SSH_AUTH_SOCK": "/run/host-services/ssh-auth.sock"]
        let base = ["PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]

        let mergedEnv = SandboxService.mergedEnvironmentVariables(base: base, overrides: overrides)

        #expect(mergedEnv.contains("PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(mergedEnv.contains("SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock"))
    }

    @Test
    func testDynamicEnvMergeOverridesExistingKey() {
        let overrides = ["FOO": "updated"]
        let base = ["FOO=original", "PATH=/usr/bin"]

        let mergedEnv = SandboxService.mergedEnvironmentVariables(base: base, overrides: overrides)

        #expect(mergedEnv.contains("FOO=updated"))
        #expect(!mergedEnv.contains("FOO=original"))
        #expect(mergedEnv.contains("PATH=/usr/bin"))
    }

    @Test
    func testDynamicEnvMergeNoOverridesLeavesBaseUnchanged() {
        let base = ["FOO=bar", "PATH=/usr/bin"]
        let mergedEnv = SandboxService.mergedEnvironmentVariables(base: base, overrides: [:])
        #expect(mergedEnv == base)
    }
}
