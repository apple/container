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

import ArgumentParser
import ContainerAPIClient
import ContainerPersistence
import Foundation
import SystemPackage

enum ListOutputFormat: String, Decodable, ExpressibleByArgument {
    case json
    case toml
}

extension Application {
    public struct PropertyList: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List system properties",
            aliases: ["ls"]
        )

        @Option(name: .long, help: "Format of the output")
        var format: ListOutputFormat = .toml

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
            let configurationFiles = [
                ConfigurationLoader.configurationFile(in: FilePath(health.appRoot.path(percentEncoded: false)), of: .appRoot),
                ConfigurationLoader.configurationFile(in: FilePath(health.installRoot.path(percentEncoded: false)), of: .installRoot),
            ]
            let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: configurationFiles)
            let properties = try SystemProperties(
                config: containerSystemConfig,
                plugin: PluginProperties.load(configurationFiles: configurationFiles)
            )
            let output =
                switch format {
                case .json: try Output.renderJSON(properties)
                case .toml: try Output.renderTOML(properties)
                }
            Output.emit(output)
        }
    }
}
