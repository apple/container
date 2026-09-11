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

import ContainerPersistence
import Foundation
import SystemPackage
import TOML

struct SystemProperties: Encodable {
    let build: BuildConfig
    let container: ContainerConfig
    let dns: DNSConfig
    let kernel: KernelConfig
    let machine: MachineConfig
    let network: NetworkConfig
    let registry: RegistryConfig
    let vminit: VminitConfig
    let plugin: [String: PluginPropertyValue]?

    init(config: ContainerSystemConfig, plugin: [String: PluginPropertyValue]) {
        self.build = config.build
        self.container = config.container
        self.dns = config.dns
        self.kernel = config.kernel
        self.machine = config.machine
        self.network = config.network
        self.registry = config.registry
        self.vminit = config.vminit
        self.plugin = plugin.isEmpty ? nil : plugin
    }
}

enum PluginProperties {
    static func load(configurationFiles: [FilePath] = ConfigurationLoader.defaultConfigFiles()) throws -> [String: PluginPropertyValue] {
        var pluginProperties: [String: PluginPropertyValue] = [:]
        for path in configurationFiles.reversed() {
            guard FileManager.default.fileExists(atPath: path.string) else {
                continue
            }
            let data = try Data(contentsOf: URL(filePath: path.string))
            guard let content = String(data: data, encoding: .utf8) else {
                continue
            }
            let document = try TOMLDecoder().decode(TOMLDocument.self, from: content)
            guard case .table(let pluginTable)? = document.values["plugin"] else {
                continue
            }
            pluginProperties = merge(pluginProperties, overlay: pluginTable)
        }
        return pluginProperties
    }

    private static func merge(
        _ base: [String: PluginPropertyValue],
        overlay: [String: PluginPropertyValue]
    ) -> [String: PluginPropertyValue] {
        base.merging(overlay) { old, new in
            if case .table(let oldTable) = old, case .table(let newTable) = new {
                return .table(merge(oldTable, overlay: newTable))
            }
            return new
        }
    }
}

enum PluginPropertyValue: Codable, Equatable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    case array([PluginPropertyValue])
    case table([String: PluginPropertyValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let table = try? container.decode([String: PluginPropertyValue].self) {
            self = .table(table)
        } else if let array = try? container.decode([PluginPropertyValue].self) {
            self = .array(array)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let float = try? container.decode(Double.self) {
            self = .float(float)
        } else if let boolean = try? container.decode(Bool.self) {
            self = .boolean(boolean)
        } else {
            throw DecodingError.typeMismatch(
                PluginPropertyValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported plugin property value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .float(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .table(let value):
            try container.encode(value)
        }
    }
}

private struct TOMLDocument: Decodable {
    let values: [String: PluginPropertyValue]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var values: [String: PluginPropertyValue] = [:]
        for key in container.allKeys {
            values[key.stringValue] = try container.decode(PluginPropertyValue.self, forKey: key)
        }
        self.values = values
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
