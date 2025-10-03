//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

struct TestCLIPluginErrors {
    @Test
    func testHelpfulMessageWhenPluginsUnavailable() throws {
        // Intentionally invoke an unknown plugin command. In CI this should run
        // without the APIServer started, so DefaultCommand will fail to create
        // a PluginLoader and emit the improved guidance.
        let cli = try CLITest()
        let (_, stderr, status) = try cli.run(arguments: ["nosuchplugin"])  // non-existent plugin name

        #expect(status != 0)
        #expect(stderr.contains("container system start"))
        #expect(stderr.contains("Plugins are unavailable") || stderr.contains("Plugin 'container-"))
        // Should include at least one computed plugin search path hint
        #expect(stderr.contains("container-plugins") || stderr.contains("container/plugins"))
    }
}
