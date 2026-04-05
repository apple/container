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

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import CryptoKit
import Foundation
import Yams

enum ComposeSupport {
    static let defaultFileNames = [
        "compose.yaml",
        "compose.yml",
        "docker-compose.yaml",
        "docker-compose.yml",
    ]

    static let projectLabel = "com.apple.container.compose.project"
    static let serviceLabel = "com.apple.container.compose.service"
    static let versionLabel = "com.apple.container.compose.version"
    static let configHashLabel = "com.apple.container.compose.config-hash"
    static let managedVersion = "mvp"

    static let managedContainerLabels = [
        versionLabel: managedVersion
    ]

    static func discoveredComposeFile(in directory: URL) throws -> URL {
        for name in defaultFileNames {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        throw ContainerizationError(
            .notFound,
            message: "no Compose file found. Looked for: \(defaultFileNames.joined(separator: ", "))"
        )
    }

    static func resolveComposeFile(input: String?) throws -> URL {
        if let input, !input.isEmpty {
            let url = URL(fileURLWithPath: input, relativeTo: .currentDirectory()).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw ContainerizationError(.notFound, message: "Compose file not found at \(url.path(percentEncoded: false))")
            }
            return url
        }
        return try discoveredComposeFile(in: URL.currentDirectory())
    }

    static func loadProject(
        filePath: String?,
        projectName: String?,
        profiles: [String],
        envFiles: [String]
    ) throws -> ComposeProject {
        let fileURL = try resolveComposeFile(input: filePath)
        let projectDirectory = fileURL.deletingLastPathComponent()
        let rawData = try Data(contentsOf: fileURL)
        guard let rawText = String(data: rawData, encoding: .utf8) else {
            throw ContainerizationError(.invalidArgument, message: "Compose file contains invalid UTF-8")
        }

        try validateRawComposeYaml(rawText)

        let interpolationEnv = try interpolationEnvironment(
            projectDirectory: projectDirectory,
            explicitEnvFiles: envFiles
        )
        let interpolated = try interpolate(rawText, environment: interpolationEnv)

        let decoder = YAMLDecoder()
        let definition = try decoder.decode(ComposeFileDefinition.self, from: interpolated)
        return try ComposeProject(
            definition: definition,
            fileURL: fileURL,
            explicitProjectName: projectName,
            selectedProfiles: Set(profiles)
        )
    }

    static func interpolationEnvironment(
        projectDirectory: URL,
        explicitEnvFiles: [String]
    ) throws -> [String: String] {
        var merged = ProcessInfo.processInfo.environment

        let defaultEnvURL = projectDirectory.appendingPathComponent(".env")
        if FileManager.default.fileExists(atPath: defaultEnvURL.path(percentEncoded: false)) {
            merged.merge(try parseEnvFile(defaultEnvURL)) { _, new in new }
        }

        for envFile in explicitEnvFiles {
            let envURL = URL(fileURLWithPath: envFile, relativeTo: .currentDirectory()).standardizedFileURL
            merged.merge(try parseEnvFile(envURL)) { _, new in new }
        }

        return merged
    }

    static func parseEnvFile(_ url: URL) throws -> [String: String] {
        let lines = try Parser.envFile(path: url.path(percentEncoded: false))
        var result: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1)
            let key = String(parts[0])
            let value = parts.count == 2 ? String(parts[1]) : ""
            result[key] = value
        }
        return result
    }

    static func interpolate(_ input: String, environment: [String: String]) throws -> String {
        var output = ""
        var index = input.startIndex

        func readVariableName(from start: String.Index) -> (String, String.Index) {
            var cursor = start
            while cursor < input.endIndex {
                let ch = input[cursor]
                if ch.isLetter || ch.isNumber || ch == "_" {
                    cursor = input.index(after: cursor)
                } else {
                    break
                }
            }
            return (String(input[start..<cursor]), cursor)
        }

        while index < input.endIndex {
            let ch = input[index]
            guard ch == "$" else {
                output.append(ch)
                index = input.index(after: index)
                continue
            }

            let next = input.index(after: index)
            guard next < input.endIndex else {
                output.append(ch)
                break
            }

            if input[next] == "$" {
                output.append("$")
                index = input.index(after: next)
                continue
            }

            if input[next] == "{" {
                guard let closing = input[next...].firstIndex(of: "}") else {
                    throw ContainerizationError(.invalidArgument, message: "unterminated variable interpolation in Compose file")
                }
                let bodyStart = input.index(after: next)
                let body = String(input[bodyStart..<closing])
                let value: String
                if let defaultRange = body.range(of: ":-") {
                    let key = String(body[..<defaultRange.lowerBound])
                    let fallback = String(body[defaultRange.upperBound...])
                    value = environment[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
                } else {
                    value = environment[body] ?? ""
                }
                output.append(value)
                index = input.index(after: closing)
                continue
            }

            let (name, cursor) = readVariableName(from: next)
            if name.isEmpty {
                output.append("$")
                index = next
                continue
            }
            output.append(environment[name] ?? "")
            index = cursor
        }

        return output
    }

    static func validateRawComposeYaml(_ yaml: String) throws {
        guard let raw = try Yams.load(yaml: yaml) else {
            throw ContainerizationError(.invalidArgument, message: "Compose file is empty")
        }
        guard let top = raw as? [String: Any] else {
            throw ContainerizationError(.invalidArgument, message: "Compose file must contain a top-level mapping")
        }

        try validateKeys(
            actual: Set(top.keys),
            allowed: ["version", "name", "services", "networks", "volumes"],
            path: "top-level"
        )

        if let services = top["services"] as? [String: Any] {
            for (serviceName, rawService) in services {
                guard let service = rawService as? [String: Any] else {
                    throw ContainerizationError(.invalidArgument, message: "service '\(serviceName)' must be a mapping")
                }
                try validateKeys(
                    actual: Set(service.keys),
                    allowed: [
                        "image", "build", "command", "entrypoint", "environment", "env_file",
                        "ports", "volumes", "depends_on", "networks", "working_dir",
                        "user", "tty", "stdin_open", "profiles", "healthcheck"
                    ],
                    path: "services.\(serviceName)"
                )
                try validateBuild(service["build"], path: "services.\(serviceName).build")
                try validateDependsOn(service["depends_on"], path: "services.\(serviceName).depends_on")
                try validateNetworks(service["networks"], path: "services.\(serviceName).networks")
                try validatePorts(service["ports"], path: "services.\(serviceName).ports")
                try validateVolumes(service["volumes"], path: "services.\(serviceName).volumes")
                try validateHealthcheck(service["healthcheck"], path: "services.\(serviceName).healthcheck")
            }
        }

        if let volumes = top["volumes"] as? [String: Any] {
            for (name, rawVolume) in volumes {
                guard let volume = rawVolume as? [String: Any] else {
                    continue
                }
                try validateKeys(actual: Set(volume.keys), allowed: [], path: "volumes.\(name)")
            }
        }

        if let networks = top["networks"] as? [String: Any] {
            for (name, rawNetwork) in networks {
                guard let network = rawNetwork as? [String: Any] else {
                    continue
                }
                try validateKeys(actual: Set(network.keys), allowed: [], path: "networks.\(name)")
            }
        }
    }

    private static func validateBuild(_ raw: Any?, path: String) throws {
        guard let raw else { return }
        guard let build = raw as? [String: Any] else { return }
        try validateKeys(actual: Set(build.keys), allowed: ["context", "dockerfile", "args", "target"], path: path)
    }

    private static func validateDependsOn(_ raw: Any?, path: String) throws {
        guard let dict = raw as? [String: Any] else { return }
        for (serviceName, value) in dict {
            guard let conditionMap = value as? [String: Any] else {
                throw ContainerizationError(.unsupported, message: "\(path).\(serviceName) must be a mapping")
            }
            try validateKeys(actual: Set(conditionMap.keys), allowed: ["condition"], path: "\(path).\(serviceName)")
            if let condition = conditionMap["condition"] as? String {
                let supportedConditions = [
                    "service_started",
                    "service_healthy",
                ]
                guard supportedConditions.contains(condition) else {
                    throw ContainerizationError(.unsupported, message: "\(path).\(serviceName).condition '\(condition)' is not supported")
                }
            }
        }
    }

    private static func validateNetworks(_ raw: Any?, path: String) throws {
        guard let dict = raw as? [String: Any] else { return }
        for (networkName, value) in dict {
            guard let options = value as? [String: Any] else {
                throw ContainerizationError(.unsupported, message: "\(path).\(networkName) must be a mapping")
            }
            if !options.isEmpty {
                throw ContainerizationError(.unsupported, message: "\(path).\(networkName) options are not supported")
            }
        }
    }

    private static func validatePorts(_ raw: Any?, path: String) throws {
        guard let ports = raw as? [Any] else { return }
        for (index, value) in ports.enumerated() {
            guard let portMap = value as? [String: Any] else { continue }
            try validateKeys(actual: Set(portMap.keys), allowed: ["target", "published", "host_ip", "protocol"], path: "\(path)[\(index)]")
        }
    }

    private static func validateVolumes(_ raw: Any?, path: String) throws {
        guard let volumes = raw as? [Any] else { return }
        for (index, value) in volumes.enumerated() {
            guard let volumeMap = value as? [String: Any] else { continue }
            try validateKeys(actual: Set(volumeMap.keys), allowed: ["type", "source", "target", "read_only"], path: "\(path)[\(index)]")
        }
    }

    private static func validateHealthcheck(_ raw: Any?, path: String) throws {
        guard let healthcheck = raw as? [String: Any] else { return }
        try validateKeys(
            actual: Set(healthcheck.keys),
            allowed: ["test", "interval", "timeout", "retries", "start_period"],
            path: path
        )
    }

    private static func validateKeys(actual: Set<String>, allowed: Set<String>, path: String) throws {
        let unsupported = actual.subtracting(allowed)
        guard unsupported.isEmpty else {
            let key = unsupported.sorted().joined(separator: ", ")
            throw ContainerizationError(.unsupported, message: "unsupported Compose keys at \(path): \(key)")
        }
    }

    static func hashService(_ service: NormalizedComposeService) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(service)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func composeLabels(project: String, service: String, configHash: String) -> [String: String] {
        managedContainerLabels.merging([
            projectLabel: project,
            serviceLabel: service,
            configHashLabel: configHash,
        ]) { _, new in new }
    }

    static func projectResourceLabels(project: String) -> [String: String] {
        [
            projectLabel: project,
            versionLabel: managedVersion,
        ]
    }

    static func topologicalServices(_ services: [String: NormalizedComposeService]) throws -> [NormalizedComposeService] {
        var ordered: [NormalizedComposeService] = []
        var visiting = Set<String>()
        var visited = Set<String>()

        func visit(_ name: String) throws {
            guard !visited.contains(name) else { return }
            if visiting.contains(name) {
                throw ContainerizationError(.invalidArgument, message: "circular depends_on graph involving service '\(name)'")
            }
            guard let service = services[name] else {
                throw ContainerizationError(.invalidArgument, message: "service '\(name)' not found in project")
            }
            visiting.insert(name)
            for dependency in service.dependsOn {
                guard services[dependency] != nil else {
                    throw ContainerizationError(.invalidArgument, message: "service '\(name)' depends on missing service '\(dependency)'")
                }
                try visit(dependency)
            }
            visiting.remove(name)
            visited.insert(name)
            ordered.append(service)
        }

        for name in services.keys.sorted() {
            try visit(name)
        }
        return ordered
    }
}

struct ComposeFileDefinition: Decodable {
    var version: String?
    var name: String?
    var services: [String: ComposeServiceDefinition]
    var networks: [String: ComposeNamedNetwork] = [:]
    var volumes: [String: ComposeNamedVolume] = [:]

    enum CodingKeys: String, CodingKey {
        case version
        case name
        case services
        case networks
        case volumes
    }

    init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try keyed.decodeIfPresent(String.self, forKey: .version)
        self.name = try keyed.decodeIfPresent(String.self, forKey: .name)
        self.services = try keyed.decode([String: ComposeServiceDefinition].self, forKey: .services)
        self.networks = try keyed.decodeIfPresent([String: ComposeNamedNetwork].self, forKey: .networks) ?? [:]
        self.volumes = try keyed.decodeIfPresent([String: ComposeNamedVolume].self, forKey: .volumes) ?? [:]
    }
}

struct ComposeNamedNetwork: Decodable {}

struct ComposeNamedVolume: Decodable {}

struct ComposeBuildDefinition: Codable, Sendable {
    var context: String
    var dockerfile: String?
    var args: [String: String]
    var target: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let context = try? container.decode(String.self) {
            self.context = context
            self.dockerfile = nil
            self.args = [:]
            self.target = nil
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.context = try keyed.decode(String.self, forKey: .context)
        self.dockerfile = try keyed.decodeIfPresent(String.self, forKey: .dockerfile)
        self.args = try keyed.decodeIfPresent([String: String].self, forKey: .args) ?? [:]
        self.target = try keyed.decodeIfPresent(String.self, forKey: .target)
    }
}

enum ComposeDependencyCondition: String, Codable, Sendable {
    case serviceStarted = "service_started"
    case serviceHealthy = "service_healthy"
}

struct ComposeDependencyOptions: Decodable, Sendable {
    var condition: ComposeDependencyCondition = .serviceStarted
}

enum ComposeHealthcheckTest: Codable, Sendable {
    case none
    case shell(String)
    case exec([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            if raw == "NONE" {
                self = .none
            } else {
                self = .shell(raw)
            }
            return
        }

        let values = try container.decode([String].self)
        if values == ["NONE"] {
            self = .none
            return
        }
        if let first = values.first, first == "CMD-SHELL" {
            self = .shell(values.dropFirst().joined(separator: " "))
            return
        }
        if let first = values.first, first == "CMD" {
            self = .exec(Array(values.dropFirst()))
            return
        }
        self = .exec(values)
    }
}

struct ComposeHealthcheckDefinition: Codable, Sendable {
    var test: ComposeHealthcheckTest
    var interval: Duration
    var timeout: Duration
    var retries: Int
    var startPeriod: Duration

    enum CodingKeys: String, CodingKey {
        case test
        case interval
        case timeout
        case retries
        case startPeriod = "start_period"
    }

    init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.test = try keyed.decode(ComposeHealthcheckTest.self, forKey: .test)
        self.interval = try keyed.decodeIfPresent(ComposeDuration.self, forKey: .interval)?.duration ?? .seconds(30)
        self.timeout = try keyed.decodeIfPresent(ComposeDuration.self, forKey: .timeout)?.duration ?? .seconds(30)
        self.retries = try keyed.decodeIfPresent(Int.self, forKey: .retries) ?? 3
        self.startPeriod = try keyed.decodeIfPresent(ComposeDuration.self, forKey: .startPeriod)?.duration ?? .zero
    }
}

private struct ComposeDuration: Decodable {
    let duration: Duration

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            self.duration = .milliseconds(Int64(seconds * 1000))
            return
        }
        let raw = try container.decode(String.self)
        self.duration = try Self.parse(raw)
    }

    private static func parse(_ raw: String) throws -> Duration {
        let pattern = #/^(\d+)(ms|s|m|h)$/#
        guard let match = raw.wholeMatch(of: pattern) else {
            throw ContainerizationError(.invalidArgument, message: "unsupported Compose duration '\(raw)'")
        }
        let magnitude = Int64(match.1) ?? 0
        switch String(match.2) {
        case "ms":
            return .milliseconds(magnitude)
        case "s":
            return .seconds(magnitude)
        case "m":
            return .seconds(magnitude * 60)
        case "h":
            return .seconds(magnitude * 3600)
        default:
            throw ContainerizationError(.invalidArgument, message: "unsupported Compose duration '\(raw)'")
        }
    }
}

enum ComposeShellCommand: Codable, Sendable {
    case string(String)
    case array([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        self = .array(try container.decode([String].self))
    }

    func flattenedForExecution() throws -> [String] {
        switch self {
        case .string(let value):
            return try Self.tokenize(value)
        case .array(let values):
            return values
        }
    }

    private static func tokenize(_ value: String) throws -> [String] {
        enum State {
            case unquoted
            case singleQuoted
            case doubleQuoted
        }

        var state: State = .unquoted
        var escapeNext = false
        var tokenInProgress = false
        var current = ""
        var tokens: [String] = []

        for character in value {
            if escapeNext {
                current.append(character)
                tokenInProgress = true
                escapeNext = false
                continue
            }

            switch state {
            case .unquoted:
                if character == "\\" {
                    escapeNext = true
                } else if character == "'" {
                    state = .singleQuoted
                    tokenInProgress = true
                } else if character == "\"" {
                    state = .doubleQuoted
                    tokenInProgress = true
                } else if character.isWhitespace {
                    if tokenInProgress {
                        tokens.append(current)
                        current = ""
                        tokenInProgress = false
                    }
                } else {
                    current.append(character)
                    tokenInProgress = true
                }
            case .singleQuoted:
                if character == "'" {
                    state = .unquoted
                } else {
                    current.append(character)
                }
            case .doubleQuoted:
                if character == "\\" {
                    escapeNext = true
                } else if character == "\"" {
                    state = .unquoted
                } else {
                    current.append(character)
                }
            }
        }

        if escapeNext || state != .unquoted {
            throw ContainerizationError(.invalidArgument, message: "unterminated quoted command '\(value)'")
        }
        if tokenInProgress {
            tokens.append(current)
        }
        return tokens
    }
}

enum ComposeEnvironment: Decodable {
    case list([String])
    case dictionary([String: String?])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            self = .list(list)
            return
        }
        self = .dictionary(try container.decode([String: String?].self))
    }

    func resolvedEntries() -> [String] {
        switch self {
        case .list(let values):
            return values
        case .dictionary(let values):
            return values.keys.sorted().map { key in
                let value = values[key] ?? nil
                return "\(key)=\(value ?? "")"
            }
        }
    }
}

enum ComposeDependsOn: Decodable {
    case list([String])
    case map([String: ComposeDependencyOptions])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            self = .list(list)
            return
        }
        self = .map(try container.decode([String: ComposeDependencyOptions].self))
    }

    var services: [String] {
        switch self {
        case .list(let list):
            return list
        case .map(let map):
            return map.keys.sorted()
        }
    }

    var dependencies: [String: ComposeDependencyCondition] {
        switch self {
        case .list(let list):
            return Dictionary(uniqueKeysWithValues: list.map { ($0, .serviceStarted) })
        case .map(let map):
            return map.mapValues(\.condition)
        }
    }
}

struct EmptyComposeOptions: Decodable {}

enum ComposeNetworks: Decodable {
    case list([String])
    case map([String: EmptyComposeOptions])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            self = .list(list)
            return
        }
        self = .map(try container.decode([String: EmptyComposeOptions].self))
    }

    var names: [String] {
        switch self {
        case .list(let list):
            return list
        case .map(let map):
            return map.keys.sorted()
        }
    }
}

struct ComposePortDefinition: Codable, Sendable {
    var hostIP: String?
    var published: String?
    var target: String
    var protocolName: String?
    var raw: String?

    enum CodingKeys: String, CodingKey {
        case hostIP = "host_ip"
        case published
        case target
        case protocolName = "protocol"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            self.raw = raw
            self.hostIP = nil
            self.published = nil
            self.target = ""
            self.protocolName = nil
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.raw = nil
        self.hostIP = try keyed.decodeIfPresent(String.self, forKey: .hostIP)
        self.published = try keyed.decodeIfPresent(String.self, forKey: .published)
        self.target = try keyed.decode(String.self, forKey: .target)
        self.protocolName = try keyed.decodeIfPresent(String.self, forKey: .protocolName)
    }

    func asPublishSpec() throws -> String {
        if let raw {
            return raw
        }
        guard let published, !published.isEmpty else {
            throw ContainerizationError(.unsupported, message: "Compose ports without a published host port are not supported")
        }
        let proto = protocolName ?? "tcp"
        if let hostIP, !hostIP.isEmpty {
            return "\(hostIP):\(published):\(target)/\(proto)"
        }
        return "\(published):\(target)/\(proto)"
    }
}

struct ComposeVolumeDefinition: Codable, Sendable {
    var raw: String?
    var type: String?
    var source: String?
    var target: String?
    var readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case source
        case target
        case readOnly = "read_only"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            self.raw = raw
            self.type = nil
            self.source = nil
            self.target = nil
            self.readOnly = nil
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.raw = nil
        self.type = try keyed.decodeIfPresent(String.self, forKey: .type)
        self.source = try keyed.decodeIfPresent(String.self, forKey: .source)
        self.target = try keyed.decodeIfPresent(String.self, forKey: .target)
        self.readOnly = try keyed.decodeIfPresent(Bool.self, forKey: .readOnly)
    }
}

struct ComposeServiceDefinition: Decodable {
    var image: String?
    var build: ComposeBuildDefinition?
    var command: ComposeShellCommand?
    var entrypoint: ComposeShellCommand?
    var environment: ComposeEnvironment?
    var envFile: [String]
    var ports: [ComposePortDefinition]
    var volumes: [ComposeVolumeDefinition]
    var dependsOn: [String]
    var dependencyConditions: [String: ComposeDependencyCondition]
    var networks: [String]
    var workingDir: String?
    var user: String?
    var tty: Bool
    var stdinOpen: Bool
    var profiles: [String]
    var healthcheck: ComposeHealthcheckDefinition?

    enum CodingKeys: String, CodingKey {
        case image
        case build
        case command
        case entrypoint
        case environment
        case envFile = "env_file"
        case ports
        case volumes
        case dependsOn = "depends_on"
        case networks
        case workingDir = "working_dir"
        case user
        case tty
        case stdinOpen = "stdin_open"
        case profiles
        case healthcheck
    }

    init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.image = try keyed.decodeIfPresent(String.self, forKey: .image)
        self.build = try keyed.decodeIfPresent(ComposeBuildDefinition.self, forKey: .build)
        self.command = try keyed.decodeIfPresent(ComposeShellCommand.self, forKey: .command)
        self.entrypoint = try keyed.decodeIfPresent(ComposeShellCommand.self, forKey: .entrypoint)
        self.environment = try keyed.decodeIfPresent(ComposeEnvironment.self, forKey: .environment)
        if let envFiles = try? keyed.decode([String].self, forKey: .envFile) {
            self.envFile = envFiles
        } else if let envFile = try? keyed.decode(String.self, forKey: .envFile) {
            self.envFile = [envFile]
        } else {
            self.envFile = []
        }
        self.ports = try keyed.decodeIfPresent([ComposePortDefinition].self, forKey: .ports) ?? []
        self.volumes = try keyed.decodeIfPresent([ComposeVolumeDefinition].self, forKey: .volumes) ?? []
        let dependsOn = try keyed.decodeIfPresent(ComposeDependsOn.self, forKey: .dependsOn)
        self.dependsOn = dependsOn?.services ?? []
        self.dependencyConditions = dependsOn?.dependencies ?? [:]
        self.networks = (try keyed.decodeIfPresent(ComposeNetworks.self, forKey: .networks)?.names) ?? []
        self.workingDir = try keyed.decodeIfPresent(String.self, forKey: .workingDir)
        self.user = try keyed.decodeIfPresent(String.self, forKey: .user)
        self.tty = try keyed.decodeIfPresent(Bool.self, forKey: .tty) ?? false
        self.stdinOpen = try keyed.decodeIfPresent(Bool.self, forKey: .stdinOpen) ?? false
        self.profiles = try keyed.decodeIfPresent([String].self, forKey: .profiles) ?? []
        self.healthcheck = try keyed.decodeIfPresent(ComposeHealthcheckDefinition.self, forKey: .healthcheck)
    }
}

struct NormalizedComposeDependency: Codable, Sendable, Equatable {
    var service: String
    var condition: ComposeDependencyCondition
}

struct NormalizedComposeBuild: Codable, Sendable {
    var contextDirectory: String
    var dockerfilePath: String?
    var args: [String: String]
    var target: String?
}

struct NormalizedComposeService: Codable, Sendable {
    var name: String
    var containerName: String
    var image: String
    var build: NormalizedComposeBuild?
    var commandArguments: [String]
    var entrypoint: String?
    var environment: [String]
    var ports: [String]
    var volumes: [String]
    var dependsOn: [String]
    var dependencyConditions: [NormalizedComposeDependency]
    var networks: [String]
    var workingDir: String?
    var user: String?
    var tty: Bool
    var stdinOpen: Bool
    var healthcheck: ComposeHealthcheckDefinition?
}

struct ComposeProject: Codable, Sendable {
    var fileURL: URL
    var directoryURL: URL
    var name: String
    var services: [String: NormalizedComposeService]
    var networks: [String]
    var volumes: [String]

    init(
        definition: ComposeFileDefinition,
        fileURL: URL,
        explicitProjectName: String?,
        selectedProfiles: Set<String>
    ) throws {
        let projectDirectory = fileURL.deletingLastPathComponent()
        self.fileURL = fileURL
        self.directoryURL = projectDirectory

        let baseName = explicitProjectName
            ?? definition.name
            ?? fileURL.deletingLastPathComponent().lastPathComponent
        try Utility.validEntityName(baseName)
        self.name = baseName

        let declaredNetworks = Set(definition.networks.keys)
        let declaredVolumes = Set(definition.volumes.keys)

        var normalizedServices: [String: NormalizedComposeService] = [:]
        var usedNetworks = Set<String>()
        var usedVolumes = Set<String>()

        for serviceName in definition.services.keys.sorted() {
            let service = definition.services[serviceName]!
            if !selectedProfiles.isEmpty && !service.profiles.isEmpty && selectedProfiles.isDisjoint(with: Set(service.profiles)) {
                continue
            }

            guard service.image != nil || service.build != nil else {
                throw ContainerizationError(.invalidArgument, message: "service '\(serviceName)' must define either image or build")
            }

            let containerName = "\(baseName)-\(serviceName)"
            try Utility.validEntityName(containerName)

            var build: NormalizedComposeBuild?
            let image: String
            if let buildDef = service.build {
                let contextURL = URL(fileURLWithPath: buildDef.context, relativeTo: directoryURL).standardizedFileURL
                let dockerfilePath = buildDef.dockerfile.map { dockerfile -> String in
                    URL(fileURLWithPath: dockerfile, relativeTo: contextURL).standardizedFileURL.path(percentEncoded: false)
                }
                build = .init(
                    contextDirectory: contextURL.path(percentEncoded: false),
                    dockerfilePath: dockerfilePath,
                    args: buildDef.args,
                    target: buildDef.target
                )
                image = service.image ?? "\(baseName)-\(serviceName):compose"
            } else {
                image = service.image!
            }

            let envFileEntries = try service.envFile.flatMap { envFile in
                let envURL = URL(fileURLWithPath: envFile, relativeTo: projectDirectory).standardizedFileURL
                return try Parser.envFile(path: envURL.path(percentEncoded: false))
            }
            let inlineEnvironment = service.environment?.resolvedEntries() ?? []
            let environment = Self.mergeKeyValueEntries(envFileEntries + inlineEnvironment)

            let dependencyConditions = service.dependencyConditions.keys.sorted().map {
                NormalizedComposeDependency(service: $0, condition: service.dependencyConditions[$0] ?? .serviceStarted)
            }

            var commandArguments = try service.command?.flattenedForExecution() ?? []
            var entrypoint: String?
            if let entrypointCommand = try service.entrypoint?.flattenedForExecution(), !entrypointCommand.isEmpty {
                entrypoint = entrypointCommand.first
                commandArguments = Array(entrypointCommand.dropFirst()) + commandArguments
            }

            var serviceNetworks = service.networks
            if serviceNetworks.isEmpty {
                serviceNetworks = ["default"]
            }
            let resolvedNetworks = try serviceNetworks.map { networkName -> String in
                if networkName == "default" {
                    return "\(baseName)_default"
                }
                guard declaredNetworks.contains(networkName) else {
                    throw ContainerizationError(.invalidArgument, message: "service '\(serviceName)' references undefined network '\(networkName)'")
                }
                return "\(baseName)_\(networkName)"
            }
            usedNetworks.formUnion(resolvedNetworks)

            let resolvedVolumes = try service.volumes.map { volume -> String in
                if let raw = volume.raw {
                    return try Self.rewriteRawVolume(raw, declaredVolumes: declaredVolumes, projectName: baseName, relativeTo: projectDirectory, usedVolumes: &usedVolumes)
                }

                guard volume.type == nil || volume.type == "bind" || volume.type == "volume" else {
                    throw ContainerizationError(.unsupported, message: "volume type '\(volume.type ?? "")' is not supported")
                }
                guard let source = volume.source, let target = volume.target else {
                    throw ContainerizationError(.invalidArgument, message: "volume entry for service '\(serviceName)' requires source and target")
                }

                let readOnlySuffix = (volume.readOnly ?? false) ? ":ro" : ""
                if volume.type == "bind" || source.contains("/") || source == "." || source == ".." {
                    let absoluteSource = URL(fileURLWithPath: source, relativeTo: projectDirectory).standardizedFileURL.path(percentEncoded: false)
                    return "\(absoluteSource):\(target)\(readOnlySuffix)"
                }

                guard declaredVolumes.contains(source) else {
                    throw ContainerizationError(.invalidArgument, message: "service '\(serviceName)' references undefined volume '\(source)'")
                }
                let volumeName = "\(baseName)_\(source)"
                usedVolumes.insert(volumeName)
                return "\(volumeName):\(target)\(readOnlySuffix)"
            }

            let resolvedPorts = try service.ports.map { try $0.asPublishSpec() }

            normalizedServices[serviceName] = NormalizedComposeService(
                name: serviceName,
                containerName: containerName,
                image: image,
                build: build,
                commandArguments: commandArguments,
                entrypoint: entrypoint,
                environment: environment,
                ports: resolvedPorts,
                volumes: resolvedVolumes,
                dependsOn: service.dependsOn,
                dependencyConditions: dependencyConditions,
                networks: resolvedNetworks,
                workingDir: service.workingDir,
                user: service.user,
                tty: service.tty,
                stdinOpen: service.stdinOpen,
                healthcheck: service.healthcheck
            )
        }

        self.services = normalizedServices
        self.networks = usedNetworks.sorted()
        self.volumes = usedVolumes.sorted()
    }

    var orderedServices: [NormalizedComposeService] {
        get throws {
            try ComposeSupport.topologicalServices(services)
        }
    }

    func matchingContainers(_ containers: [ContainerSnapshot]) -> [String: ContainerSnapshot] {
        Dictionary(uniqueKeysWithValues: containers.compactMap { container in
            guard container.configuration.labels[ComposeSupport.projectLabel] == name else {
                return nil
            }
            return (container.id, container)
        })
    }

    private static func mergeKeyValueEntries(_ entries: [String]) -> [String] {
        var merged: [String: String] = [:]
        for entry in entries {
            let parts = entry.split(separator: "=", maxSplits: 1)
            let key = String(parts[0])
            let value = parts.count == 2 ? String(parts[1]) : ""
            merged[key] = value
        }
        return merged.keys.sorted().map { "\($0)=\(merged[$0] ?? "")" }
    }

    private static func rewriteRawVolume(
        _ raw: String,
        declaredVolumes: Set<String>,
        projectName: String,
        relativeTo baseURL: URL,
        usedVolumes: inout Set<String>
    ) throws -> String {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 {
            return raw
        }
        guard parts.count == 2 || parts.count == 3 else {
            throw ContainerizationError(.invalidArgument, message: "invalid volume definition: \(raw)")
        }
        let source = parts[0]
        let destination = parts[1]
        let options = parts.count == 3 ? ":\(parts[2])" : ""

        if source.contains("/") || source == "." || source == ".." {
            let absoluteSource = URL(fileURLWithPath: source, relativeTo: baseURL).standardizedFileURL.path(percentEncoded: false)
            return "\(absoluteSource):\(destination)\(options)"
        }

        guard declaredVolumes.contains(source) else {
            throw ContainerizationError(.invalidArgument, message: "undefined named volume '\(source)'")
        }

        let projectVolume = "\(projectName)_\(source)"
        usedVolumes.insert(projectVolume)
        return "\(projectVolume):\(destination)\(options)"
    }
}

private func mergeKeyValueEntries(_ entries: [String]) -> [String] {
    var merged: [String: String] = [:]
    for entry in entries {
        let parts = entry.split(separator: "=", maxSplits: 1)
        let key = String(parts[0])
        let value = parts.count == 2 ? String(parts[1]) : ""
        merged[key] = value
    }
    return merged.keys.sorted().map { "\($0)=\(merged[$0] ?? "")" }
}

private extension URL {
    static func currentDirectory() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}
