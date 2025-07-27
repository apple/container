//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import Yams

// MARK: - Top Level Compose File

/// Represents a Docker Compose file structure
///
/// This struct models the complete docker-compose.yml file format, including
/// services, networks, volumes, and version information. It supports the
/// standard Docker Compose specification with extensions for Apple Container.
///
/// Example:
/// ```yaml
/// version: '3.8'
/// services:
///   web:
///     image: nginx:latest
///     ports:
///       - "8080:80"
/// networks:
///   default:
///     driver: bridge
/// ```
public struct ComposeFile: Codable {
    public let version: String?
    public let services: [String: ComposeService]
    public let networks: [String: ComposeNetwork]?
    public let volumes: [String: ComposeVolume]?
    
    public init(version: String? = nil,
                services: [String: ComposeService] = [:],
                networks: [String: ComposeNetwork]? = nil,
                volumes: [String: ComposeVolume]? = nil) {
        self.version = version
        self.services = services
        self.networks = networks
        self.volumes = volumes
    }
}

// MARK: - Service Definition

public struct ComposeService: Codable {
    public let image: String?
    public let build: BuildConfig?
    public let command: StringOrList?
    public let entrypoint: StringOrList?
    public let workingDir: String?
    public let environment: Environment?
    public let envFile: StringOrList?
    // Support both short and long form service volume definitions
    public let volumes: [ServiceVolume]?
    public let ports: [String]?
    public let networks: NetworkConfig?
    public let dependsOn: DependsOn?
    public let deploy: DeployConfig?
    public let memLimit: String?
    public let cpus: String?
    public let containerName: String?
    public let healthcheck: HealthCheckConfig?
    public let profiles: [String]?
    public let extends: ExtendsConfig?
    public let restart: String?
    public let labels: Labels?
    public let tty: Bool?
    public let stdinOpen: Bool?
    
    enum CodingKeys: String, CodingKey {
        case image, build, command, entrypoint
        case workingDir = "working_dir"
        case environment
        case envFile = "env_file"
        case volumes, ports, networks
        case dependsOn = "depends_on"
        case deploy
        case memLimit = "mem_limit"
        case cpus
        case containerName = "container_name"
        case healthcheck, profiles, extends, restart, labels
        case tty
        case stdinOpen = "stdin_open"
    }
}

// MARK: - Build Configuration

public struct BuildConfig: Codable, Sendable {
    public let context: String?
    public let dockerfile: String?
    public let args: [String: String]?
    public let target: String?
}

// MARK: - Deploy Configuration

public struct DeployConfig: Codable {
    public let resources: Resources?
}

public struct Resources: Codable {
    public let limits: ResourceLimits?
    public let reservations: ResourceReservations?
}

public struct ResourceLimits: Codable {
    public let cpus: String?
    public let memory: String?
}

public struct ResourceReservations: Codable {
    public let cpus: String?
    public let memory: String?
}

// MARK: - Health Check Configuration

public struct HealthCheckConfig: Codable {
    public let test: StringOrList?
    public let interval: String?
    public let timeout: String?
    public let retries: Int?
    public let startPeriod: String?
    public let disable: Bool?
    
    enum CodingKeys: String, CodingKey {
        case test, interval, timeout, retries
        case startPeriod = "start_period"
        case disable
    }
}

// MARK: - Extends Configuration

public struct ExtendsConfig: Codable {
    public let service: String
    public let file: String?
}

// MARK: - Network Configuration

public struct ComposeNetwork: Codable {
    public let driver: String?
    public let external: External?
    public let name: String?
    
    public enum External: Codable {
        case bool(Bool)
        case config(ExternalConfig)
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let boolValue = try? container.decode(Bool.self) {
                self = .bool(boolValue)
            } else if let config = try? container.decode(ExternalConfig.self) {
                self = .config(config)
            } else {
                throw DecodingError.typeMismatch(External.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected Bool or ExternalConfig"))
            }
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let value):
                try container.encode(value)
            case .config(let config):
                try container.encode(config)
            }
        }
    }
    
    public struct ExternalConfig: Codable {
        public let name: String?
    }
}

// MARK: - Volume Configuration

public struct ComposeVolume: Codable {
    public let driver: String?
    public let external: ComposeNetwork.External?
    public let name: String?
    
    public init(driver: String? = nil, external: ComposeNetwork.External? = nil, name: String? = nil) {
        self.driver = driver
        self.external = external
        self.name = name
    }
    
    public init(from decoder: Decoder) throws {
        // Try to decode as a dictionary first
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let driver = try container.decodeIfPresent(String.self, forKey: .driver)
            let external = try container.decodeIfPresent(ComposeNetwork.External.self, forKey: .external)
            let name = try container.decodeIfPresent(String.self, forKey: .name)
            self.init(driver: driver, external: external, name: name)
        } catch {
            // If decoding as dictionary fails, it might be an empty value
            // Initialize with all nil values
            self.init()
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case driver, external, name
    }
}

// MARK: - Helper Types

/// Service volume entry supporting both short string and long object form
public enum ServiceVolume: Codable, Equatable {
    case string(String)
    case object(ServiceVolumeObject)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        if let o = try? container.decode(ServiceVolumeObject.self) {
            self = .object(o)
            return
        }
        throw DecodingError.typeMismatch(ServiceVolume.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or volume object"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .object(let o):
            try container.encode(o)
        }
    }
}

/// Subset of Compose long-form service volume that we support plugin-side
public struct ServiceVolumeObject: Codable, Equatable {
    public struct Bind: Codable, Equatable {
        public let propagation: String?
    }
    public struct Tmpfs: Codable, Equatable {
        public let size: Int64?
    }

    public let type: String?          // bind | volume | tmpfs
    public let source: String?
    public let target: String
    public let readOnly: Bool?
    public let bind: Bind?
    public let tmpfs: Tmpfs?

    enum CodingKeys: String, CodingKey {
        case type, source, target
        case readOnly = "read_only"
        case bind, tmpfs
    }
}

public enum StringOrList: Codable, Equatable {
    case string(String)
    case list([String])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let list = try? container.decode([String].self) {
            self = .list(list)
        } else {
            throw DecodingError.typeMismatch(StringOrList.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected String or [String]"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .list(let list):
            try container.encode(list)
        }
    }
    
    public var asArray: [String] {
        switch self {
        case .string(let str):
            return [str]
        case .list(let list):
            return list
        }
    }
}

public enum Environment: Codable {
    case list([String])
    case dict([String: String])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            // Validate keys in list form (handles quotes and inline comments)
            for item in list {
                var head = item
                if let hash = head.firstIndex(of: "#") {
                    head = String(head[..<hash])
                }
                let keyRaw = String(head.split(separator: "=", maxSplits: 1).first ?? "")
                let key = keyRaw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"")))
                if !key.isEmpty && !Environment.isValidName(key) {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid environment variable name: '\(key)'")
                }
            }
            self = .list(list)
        } else if let dict = try? container.decode([String: String].self) {
            for (k, _) in dict {
                let key = k.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"")))
                if !Environment.isValidName(key) {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid environment variable name: '\(k)'")
                }
            }
            self = .dict(dict)
        } else {
            throw DecodingError.typeMismatch(Environment.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected [String] or [String: String]"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .list(let list):
            try container.encode(list)
        case .dict(let dict):
            try container.encode(dict)
        }
    }
    
    public var asDictionary: [String: String] {
        switch self {
        case .list(let list):
            var dict: [String: String] = [:]
            for item in list {
                var head = item
                if let hash = head.firstIndex(of: "#") {
                    head = String(head[..<hash])
                }
                let parts = head.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let k = String(parts[0]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"")))
                    let v = String(parts[1]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    dict[k] = v
                }
            }
            return dict
        case .dict(let dict):
            return dict
        }
    }

    private static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        func isAlphaOrUnderscore(_ s: Unicode.Scalar) -> Bool {
            return ("A"..."Z").contains(s) || ("a"..."z").contains(s) || s == "_"
        }
        func isAlnumOrUnderscore(_ s: Unicode.Scalar) -> Bool {
            return isAlphaOrUnderscore(s) || ("0"..."9").contains(s)
        }
        guard isAlphaOrUnderscore(first) else { return false }
        for s in name.unicodeScalars.dropFirst() {
            if !isAlnumOrUnderscore(s) { return false }
        }
        return true
    }
}

public enum NetworkConfig: Codable {
    case list([String])
    case dict([String: NetworkServiceConfig])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            self = .list(list)
        } else if let dict = try? container.decode([String: NetworkServiceConfig].self) {
            self = .dict(dict)
        } else {
            throw DecodingError.typeMismatch(NetworkConfig.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected [String] or network configuration"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .list(let list):
            try container.encode(list)
        case .dict(let dict):
            try container.encode(dict)
        }
    }
}

public struct NetworkServiceConfig: Codable {
    public let aliases: [String]?
}

public enum DependsOn: Codable {
    case list([String])
    case dict([String: DependsOnConfig])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            self = .list(list)
        } else if let dict = try? container.decode([String: DependsOnConfig].self) {
            self = .dict(dict)
        } else {
            throw DecodingError.typeMismatch(DependsOn.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected [String] or depends_on configuration"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .list(let list):
            try container.encode(list)
        case .dict(let dict):
            try container.encode(dict)
        }
    }
    
    public var asList: [String] {
        switch self {
        case .list(let list):
            return list
        case .dict(let dict):
            return Array(dict.keys)
        }
    }
}

public struct DependsOnConfig: Codable {
    public let condition: String?
}

public enum Labels: Codable {
    case list([String])
    case dict([String: String])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            self = .list(list)
        } else if let dict = try? container.decode([String: String].self) {
            self = .dict(dict)
        } else {
            throw DecodingError.typeMismatch(Labels.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected [String] or [String: String]"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .list(let list):
            try container.encode(list)
        case .dict(let dict):
            try container.encode(dict)
        }
    }
    
    public var asDictionary: [String: String] {
        switch self {
        case .dict(let dict):
            return dict
        case .list(let list):
            var dict: [String: String] = [:]
            for item in list {
                let parts = item.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    dict[String(parts[0])] = String(parts[1])
                } else if parts.count == 1 {
                    // Label without value
                    dict[String(parts[0])] = ""
                }
            }
            return dict
        }
    }
}
