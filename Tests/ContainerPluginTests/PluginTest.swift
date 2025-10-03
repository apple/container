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

import Foundation
import Testing

@testable import ContainerPlugin

struct PluginTest {
    @Test
    func testCLIPlugin() async throws {
        let config = PluginConfig(
            abstract: "abstract",
            author: "Ted Klondike",
            servicesConfig: nil
        )

        let binaryPath = "/usr/local/libexec/container/plugin/bin/container-foo"
        let plugin = Plugin(
            binaryURL: URL(filePath: binaryPath),
            config: config
        )

        #expect(plugin.name == "container-foo")
        #expect(!plugin.shouldBoot)
        #expect(plugin.getLaunchdLabel() == "com.apple.container.container-foo")
        #expect(plugin.getLaunchdLabel(instanceId: "1") == "com.apple.container.container-foo.1")
        #expect(plugin.getMachServices() == [])
        #expect(plugin.getMachServices(instanceId: "1") == [])
        #expect(plugin.getMachService(type: .runtime) == nil)
        #expect(plugin.getMachService(instanceId: "1", type: .runtime) == nil)
        #expect(!plugin.hasType(.runtime))
        #expect(!plugin.hasType(.network))
        #expect(plugin.helpText(padding: 20) == "  container-foo       abstract")
    }

    @Test
    func testServicePlugin() async throws {
        let config = PluginConfig(
            abstract: "abstract",
            author: "Ted Klondike",
            servicesConfig: .init(
                loadAtBoot: false,
                runAtLoad: false,
                services: [
                    .init(type: .runtime, description: "runtime service")
                ],
                defaultArguments: ["foo-bar"]
            )
        )

        let binaryPath = "/usr/local/libexec/container/plugin/linux-sandboxd/bin/linux-sandboxd"
        let plugin = Plugin(
            binaryURL: URL(filePath: binaryPath),
            config: config
        )

        #expect(plugin.name == "linux-sandboxd")
        #expect(!plugin.shouldBoot)
        #expect(plugin.getLaunchdLabel() == "com.apple.container.linux-sandboxd")
        #expect(plugin.getLaunchdLabel(instanceId: "1") == "com.apple.container.linux-sandboxd.1")
        #expect(
            plugin.getMachServices() == [
                "com.apple.container.runtime.linux-sandboxd"
            ])
        #expect(
            plugin.getMachServices(instanceId: "1") == [
                "com.apple.container.runtime.linux-sandboxd.1"
            ])
        #expect(plugin.getMachService(type: .runtime) == "com.apple.container.runtime.linux-sandboxd")
        #expect(plugin.getMachService(instanceId: "1", type: .runtime) == "com.apple.container.runtime.linux-sandboxd.1")
        #expect(plugin.hasType(.runtime))
        #expect(!plugin.hasType(.network))
        #expect(plugin.config.servicesConfig!.defaultArguments == ["foo-bar"])
    }

    @Test
    func testMultipleServicePlugin() async throws {
        let config = PluginConfig(
            abstract: "abstract",
            author: "Ted Klondike",
            servicesConfig: .init(
                loadAtBoot: true,
                runAtLoad: true,
                services: [
                    .init(type: .runtime, description: "runtime service"),
                    .init(type: .network, description: "network service"),
                ],
                defaultArguments: ["start", "with", "params"]
            )
        )

        let binaryPath = "/usr/local/libexec/container/plugin/hydra/bin/hydra"
        let plugin = Plugin(
            binaryURL: URL(filePath: binaryPath),
            config: config
        )

        #expect(plugin.name == "hydra")
        #expect(plugin.shouldBoot)
        #expect(plugin.getLaunchdLabel() == "com.apple.container.hydra")
        #expect(plugin.getLaunchdLabel(instanceId: "1") == "com.apple.container.hydra.1")
        #expect(
            plugin.getMachServices() == [
                "com.apple.container.runtime.hydra",
                "com.apple.container.network.hydra",
            ])
        #expect(
            plugin.getMachServices(instanceId: "1") == [
                "com.apple.container.runtime.hydra.1",
                "com.apple.container.network.hydra.1",
            ])
        #expect(plugin.getMachService(type: .network) == "com.apple.container.network.hydra")
        #expect(plugin.getMachService(instanceId: "1", type: .network) == "com.apple.container.network.hydra.1")
        #expect(plugin.hasType(.runtime))
        #expect(plugin.hasType(.network))
        #expect(plugin.config.servicesConfig!.defaultArguments == ["start", "with", "params"])
    }
}
