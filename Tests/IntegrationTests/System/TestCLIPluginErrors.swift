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

@Suite
struct TestCLIPluginErrors {
    @Test func testHelpfulMessageWhenPluginsUnavailable() async throws {
        // Intentionally invoke an unknown plugin command. In CI this should run
        // without the APIServer started, so DefaultCommand will fail to create
        // a PluginLoader and emit the improved guidance.
        try await ContainerFixture.with { f in
            let result = try f.run(["nosuchplugin"])
            #expect(result.status != 0)
            #expect(result.error.contains("container system start"))
            #expect(
                result.error.contains("Plugins are unavailable")
                    || result.error.contains("Plugin 'container-"))
            #expect(
                result.error.contains("container-plugins")
                    || result.error.contains("container/plugins"))
        }
    }
}
