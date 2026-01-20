//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

struct PluginConfigTest {
    @Test
    func testCLIPluginConfigLoad() async throws {
        let tempURL = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let configURL = tempURL.appending(path: "config.json")
        let configJson = """
            {
                "abstract" : "Default network management service",
                "author": "Apple"
            }
            """
        try configJson.write(to: configURL, atomically: true, encoding: .utf8)
        let config = try #require(try PluginConfig(configURL: configURL))

        #expect(config.isCLI)
        #expect(config.abstract == "Default network management service")
        #expect(config.author == "Apple")
    }

    @Test
    func testServicePluginConfigLoad() async throws {
        let tempURL = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let configURL = tempURL.appending(path: "config.json")
        let configJson = """
            {
                "abstract" : "Default network management service",
                "author": "Apple",
                "servicesConfig" : {
                    "loadAtBoot" : true,
                    "runAtLoad" : true,
                    "defaultArguments" : ["start"],
                    "services" : [
                        {
                            "type" : "network",
                            "description": "foo"
                        }
                    ]
                }
            }
            """
        try configJson.write(to: configURL, atomically: true, encoding: .utf8)
        let config = try #require(try PluginConfig(configURL: configURL))

        #expect(!config.isCLI)
        #expect(config.abstract == "Default network management service")
        #expect(config.author == "Apple")

        let servicesConfig = try #require(config.servicesConfig)
        #expect(servicesConfig.loadAtBoot)
        #expect(servicesConfig.runAtLoad)
        #expect(servicesConfig.services.count == 1)
        #expect(servicesConfig.services[0].type == .network)
        #expect(servicesConfig.services[0].description == "foo")
        #expect(servicesConfig.defaultArguments == ["start"])
    }
}
