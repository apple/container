//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc.
//===----------------------------------------------------------------------===//

import Testing

struct TestCLIPluginErrors {
    @Test
    func testHelpfulMessageWhenPluginsUnavailable() throws {
        // Intentionally invoke an unknown plugin command. In CI this should run
        // without the APIServer started, so DefaultCommand will fail to create
        // a PluginLoader and emit the improved guidance.
        let cli = try CLITest()
        let (_, stderr, status) = try cli.run(arguments: ["nosuchplugin"]) // non-existent plugin name

        #expect(status != 0)
        #expect(stderr.contains("container system start"))
        #expect(stderr.contains("Plugins are unavailable") || stderr.contains("Plugin 'container-"))
        // Should include at least one computed plugin search path hint
        #expect(stderr.contains("container-plugins") || stderr.contains("container/plugins"))
    }
}
