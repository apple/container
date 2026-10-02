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
import SystemPackage
import Testing

@testable import ContainerCommands

struct PluginPropertiesTests {
    @Test func renderSystemPropertiesIncludesPluginProperties() throws {
        let properties = SystemProperties(
            config: .init(),
            plugin: [
                "example": .table([
                    "enabled": .boolean(true),
                    "name": .string("demo"),
                ])
            ]
        )

        let toml = try Output.renderTOML(properties)
        #expect(toml.contains("[plugin.example]"))
        #expect(toml.contains("enabled = true"))
        #expect(toml.contains(#"name = "demo""#))

        let json = try Output.renderJSON(properties)
        #expect(json.contains(#""plugin":{"example":{"enabled":true,"name":"demo"}}"#))
    }

    @Test func loadPluginProperties() throws {
        let file = try temporaryConfig(
            """
            [plugin.example]
            enabled = true
            retries = 3
            name = "demo"
            labels = ["a", "b"]

            [plugin.example.nested]
            mode = "fast"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: file.string) }

        let properties = try PluginProperties.load(configurationFiles: [file])

        #expect(
            properties == [
                "example": .table([
                    "enabled": .boolean(true),
                    "retries": .integer(3),
                    "name": .string("demo"),
                    "labels": .array([.string("a"), .string("b")]),
                    "nested": .table(["mode": .string("fast")]),
                ])
            ]
        )
    }

    @Test func higherPrecedencePluginPropertiesOverrideLowerPrecedence() throws {
        let lower = try temporaryConfig(
            """
            [plugin.example]
            enabled = false
            retries = 1
            """
        )
        let higher = try temporaryConfig(
            """
            [plugin.example]
            enabled = true
            """
        )
        defer {
            try? FileManager.default.removeItem(atPath: lower.string)
            try? FileManager.default.removeItem(atPath: higher.string)
        }

        let properties = try PluginProperties.load(configurationFiles: [higher, lower])

        #expect(
            properties == [
                "example": .table([
                    "enabled": .boolean(true),
                    "retries": .integer(1),
                ])
            ]
        )
    }

    private func temporaryConfig(_ content: String) throws -> FilePath {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-plugin-properties-\(UUID().uuidString).toml")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return FilePath(url.path(percentEncoded: false))
    }
}
