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

/// Represents metadata operations (ENV, LABEL, ARG, etc.).
///
/// Design rationale:
/// - Unified handling of all metadata modifications
/// - No filesystem changes, only configuration
/// - Supports both build-time and runtime metadata
public struct MetadataOperation: Operation, Hashable {
    public static let operationKind = OperationKind.metadata
    public var operationKind: OperationKind { Self.operationKind }

    /// Type of metadata operation
    public let action: MetadataAction

    /// Operation metadata
    public let metadata: OperationMetadata

    public init(
        action: MetadataAction,
        metadata: OperationMetadata = OperationMetadata()
    ) {
        self.action = action
        self.metadata = metadata
    }

    public func accept<V: OperationVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Metadata Action

/// Type of metadata modification.
///
/// Design rationale:
/// - Each action is self-contained with its data
/// - Clear separation between build and runtime metadata
/// - Extensible for future metadata types
public enum MetadataAction: Sendable {
    /// Set environment variable (ENV)
    case setEnv(key: String, value: EnvironmentValue)

    /// Set multiple environment variables
    case setEnvBatch([(key: String, value: EnvironmentValue)])

    /// Set label (LABEL)
    case setLabel(key: String, value: String)

    /// Set multiple labels
    case setLabelBatch([String: String])

    /// Define build argument (ARG)
    case declareArg(name: String, defaultValue: String?)

    /// Set exposed port (EXPOSE)
    case expose(port: PortSpec)

    /// Set working directory (WORKDIR)
    case setWorkdir(path: String)

    /// Set user (USER)
    case setUser(user: User)

    /// Set entrypoint (ENTRYPOINT)
    case setEntrypoint(command: Command)

    /// Set default command (CMD)
    case setCmd(command: Command)

    /// Set shell (SHELL)
    case setShell(shell: [String])

    /// Set healthcheck (HEALTHCHECK)
    case setHealthcheck(healthcheck: Healthcheck?)

    /// Set stop signal (STOPSIGNAL)
    case setStopSignal(signal: String)

    /// Add volume (VOLUME)
    case addVolume(path: String)

    /// Add onbuild trigger (ONBUILD)
    case addOnBuild(instruction: String)
}

// MARK: - Port Specification

/// Port exposure specification.
///
/// Design rationale:
/// - Supports TCP/UDP/SCTP
/// - Range support for multiple ports
/// - Documentation via description
public struct PortSpec: Hashable, Sendable {
    public enum NetworkProtocol: String, Hashable, Sendable {
        case tcp
        case udp
        case sctp
    }

    /// Port number or range start
    public let port: Int

    /// Range end (if range)
    public let endPort: Int?

    /// Protocol
    public let `protocol`: NetworkProtocol

    /// Human-readable description
    public let description: String?

    public init(
        port: Int,
        endPort: Int? = nil,
        protocol: NetworkProtocol = .tcp,
        description: String? = nil
    ) {
        self.port = port
        self.endPort = endPort
        self.`protocol` = `protocol`
        self.description = description
    }

    /// String representation (e.g., "80/tcp", "8000-8100/udp")
    public var stringValue: String {
        guard let endPort = endPort else {
            return "\(port)/\(`protocol`.rawValue)"
        }
        return "\(port)-\(endPort)/\(`protocol`.rawValue)"
    }
}

// MARK: - Healthcheck

/// Container healthcheck configuration.
///
/// Design rationale:
/// - Matches Docker/OCI healthcheck spec
/// - Flexible timing configuration
/// - Supports disabling inherited healthchecks
public struct Healthcheck: Hashable, Sendable {
    /// Test command
    public let test: HealthcheckTest

    /// Time between checks
    public let interval: TimeInterval?

    /// Timeout for each check
    public let timeout: TimeInterval?

    /// Initial delay before first check
    public let startPeriod: TimeInterval?

    /// Number of retries before unhealthy
    public let retries: Int?

    public init(
        test: HealthcheckTest,
        interval: TimeInterval? = nil,
        timeout: TimeInterval? = nil,
        startPeriod: TimeInterval? = nil,
        retries: Int? = nil
    ) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.startPeriod = startPeriod
        self.retries = retries
    }
}

/// Healthcheck test specification.
public enum HealthcheckTest: Hashable, Sendable {
    /// No healthcheck (NONE)
    case none

    /// Command to run (CMD)
    case command(Command)

    /// Command with shell (CMD-SHELL)
    case shell(String)
}

// MARK: - Hashable & Equatable

extension MetadataAction: Hashable, Equatable {
    public static func == (lhs: MetadataAction, rhs: MetadataAction) -> Bool {
        switch (lhs, rhs) {
        case (.setEnv(let lk, let lv), .setEnv(let rk, let rv)):
            return lk == rk && lv == rv
        case (.setEnvBatch(let l), .setEnvBatch(let r)):
            guard l.count == r.count else { return false }
            for (index, (lk, lv)) in l.enumerated() {
                let (rk, rv) = r[index]
                if lk != rk || lv != rv { return false }
            }
            return true
        case (.setLabel(let lk, let lv), .setLabel(let rk, let rv)):
            return lk == rk && lv == rv
        case (.setLabelBatch(let l), .setLabelBatch(let r)):
            return l == r
        case (.declareArg(let ln, let ld), .declareArg(let rn, let rd)):
            return ln == rn && ld == rd
        case (.expose(let l), .expose(let r)):
            return l == r
        case (.setWorkdir(let l), .setWorkdir(let r)):
            return l == r
        case (.setUser(let l), .setUser(let r)):
            return l == r
        case (.setEntrypoint(let l), .setEntrypoint(let r)):
            return l == r
        case (.setCmd(let l), .setCmd(let r)):
            return l == r
        case (.setShell(let l), .setShell(let r)):
            return l == r
        case (.setHealthcheck(let l), .setHealthcheck(let r)):
            return l == r
        case (.setStopSignal(let l), .setStopSignal(let r)):
            return l == r
        case (.addVolume(let l), .addVolume(let r)):
            return l == r
        case (.addOnBuild(let l), .addOnBuild(let r)):
            return l == r
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .setEnv(let key, let value):
            hasher.combine(0)
            hasher.combine(key)
            hasher.combine(value)
        case .setEnvBatch(let vars):
            hasher.combine(1)
            for (key, value) in vars {
                hasher.combine(key)
                hasher.combine(value)
            }
        case .setLabel(let key, let value):
            hasher.combine(2)
            hasher.combine(key)
            hasher.combine(value)
        case .setLabelBatch(let labels):
            hasher.combine(3)
            hasher.combine(labels)
        case .declareArg(let name, let defaultValue):
            hasher.combine(4)
            hasher.combine(name)
            hasher.combine(defaultValue)
        case .expose(let port):
            hasher.combine(5)
            hasher.combine(port)
        case .setWorkdir(let path):
            hasher.combine(6)
            hasher.combine(path)
        case .setUser(let user):
            hasher.combine(7)
            hasher.combine(user)
        case .setEntrypoint(let command):
            hasher.combine(8)
            hasher.combine(command)
        case .setCmd(let command):
            hasher.combine(9)
            hasher.combine(command)
        case .setShell(let shell):
            hasher.combine(10)
            hasher.combine(shell)
        case .setHealthcheck(let healthcheck):
            hasher.combine(11)
            hasher.combine(healthcheck)
        case .setStopSignal(let signal):
            hasher.combine(12)
            hasher.combine(signal)
        case .addVolume(let path):
            hasher.combine(13)
            hasher.combine(path)
        case .addOnBuild(let instruction):
            hasher.combine(14)
            hasher.combine(instruction)
        }
    }
}

// MARK: - Codable

extension MetadataOperation: Codable {}
extension MetadataAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case key
        case value
        case envVars
        case labels
        case name
        case defaultValue
        case port
        case path
        case user
        case command
        case shell
        case healthcheck
        case signal
        case instruction
    }

    private struct EnvVar: Codable {
        let key: String
        let value: EnvironmentValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setEnv(let key, let value):
            try container.encode("setEnv", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(value, forKey: .value)
        case .setEnvBatch(let vars):
            try container.encode("setEnvBatch", forKey: .type)
            let envVars = vars.map { EnvVar(key: $0.key, value: $0.value) }
            try container.encode(envVars, forKey: .envVars)
        case .setLabel(let key, let value):
            try container.encode("setLabel", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(value, forKey: .value)
        case .setLabelBatch(let labels):
            try container.encode("setLabelBatch", forKey: .type)
            try container.encode(labels, forKey: .labels)
        case .declareArg(let name, let defaultValue):
            try container.encode("declareArg", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(defaultValue, forKey: .defaultValue)
        case .expose(let port):
            try container.encode("expose", forKey: .type)
            try container.encode(port, forKey: .port)
        case .setWorkdir(let path):
            try container.encode("setWorkdir", forKey: .type)
            try container.encode(path, forKey: .path)
        case .setUser(let user):
            try container.encode("setUser", forKey: .type)
            try container.encode(user, forKey: .user)
        case .setEntrypoint(let command):
            try container.encode("setEntrypoint", forKey: .type)
            try container.encode(command, forKey: .command)
        case .setCmd(let command):
            try container.encode("setCmd", forKey: .type)
            try container.encode(command, forKey: .command)
        case .setShell(let shell):
            try container.encode("setShell", forKey: .type)
            try container.encode(shell, forKey: .shell)
        case .setHealthcheck(let healthcheck):
            try container.encode("setHealthcheck", forKey: .type)
            try container.encode(healthcheck, forKey: .healthcheck)
        case .setStopSignal(let signal):
            try container.encode("setStopSignal", forKey: .type)
            try container.encode(signal, forKey: .signal)
        case .addVolume(let path):
            try container.encode("addVolume", forKey: .type)
            try container.encode(path, forKey: .path)
        case .addOnBuild(let instruction):
            try container.encode("addOnBuild", forKey: .type)
            try container.encode(instruction, forKey: .instruction)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "setEnv":
            let key = try container.decode(String.self, forKey: .key)
            let value = try container.decode(EnvironmentValue.self, forKey: .value)
            self = .setEnv(key: key, value: value)
        case "setEnvBatch":
            let envVars = try container.decode([EnvVar].self, forKey: .envVars)
            self = .setEnvBatch(envVars.map { ($0.key, $0.value) })
        case "setLabel":
            let key = try container.decode(String.self, forKey: .key)
            let value = try container.decode(String.self, forKey: .value)
            self = .setLabel(key: key, value: value)
        case "setLabelBatch":
            let labels = try container.decode([String: String].self, forKey: .labels)
            self = .setLabelBatch(labels)
        case "declareArg":
            let name = try container.decode(String.self, forKey: .name)
            let defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
            self = .declareArg(name: name, defaultValue: defaultValue)
        case "expose":
            let port = try container.decode(PortSpec.self, forKey: .port)
            self = .expose(port: port)
        case "setWorkdir":
            let path = try container.decode(String.self, forKey: .path)
            self = .setWorkdir(path: path)
        case "setUser":
            let user = try container.decode(User.self, forKey: .user)
            self = .setUser(user: user)
        case "setEntrypoint":
            let command = try container.decode(Command.self, forKey: .command)
            self = .setEntrypoint(command: command)
        case "setCmd":
            let command = try container.decode(Command.self, forKey: .command)
            self = .setCmd(command: command)
        case "setShell":
            let shell = try container.decode([String].self, forKey: .shell)
            self = .setShell(shell: shell)
        case "setHealthcheck":
            let healthcheck = try container.decodeIfPresent(Healthcheck.self, forKey: .healthcheck)
            self = .setHealthcheck(healthcheck: healthcheck)
        case "setStopSignal":
            let signal = try container.decode(String.self, forKey: .signal)
            self = .setStopSignal(signal: signal)
        case "addVolume":
            let path = try container.decode(String.self, forKey: .path)
            self = .addVolume(path: path)
        case "addOnBuild":
            let instruction = try container.decode(String.self, forKey: .instruction)
            self = .addOnBuild(instruction: instruction)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown MetadataAction type: \(type)")
        }
    }
}
extension PortSpec: Codable {
    enum CodingKeys: String, CodingKey {
        case port
        case endPort
        case `protocol`
        case description
    }
}
extension PortSpec.NetworkProtocol: Codable {}
extension Healthcheck: Codable {}
extension HealthcheckTest: Codable {}
