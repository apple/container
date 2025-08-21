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

/// Represents a command execution operation (RUN in Dockerfile).
///
/// Design rationale:
/// - Captures all execution context (env, mounts, user, workdir)
/// - Supports advanced features like secrets and SSH forwarding
/// - Shell vs exec form preserved for accurate execution
/// - Network and security controls built-in
public struct ExecOperation: Operation, Hashable {
    public static let operationKind = OperationKind.exec
    public var operationKind: OperationKind { Self.operationKind }

    /// The command to execute
    public let command: Command

    /// Environment variables
    public let environment: Environment

    /// Mounts (cache, bind, tmpfs, secret, ssh)
    public let mounts: [Mount]

    /// Working directory
    public let workingDirectory: String?

    /// User to run as
    public let user: User?

    /// Network mode
    public let network: NetworkMode

    /// Security options
    public let security: SecurityOptions

    /// Operation metadata
    public let metadata: OperationMetadata

    public init(
        command: Command,
        environment: Environment = .empty,
        mounts: [Mount] = [],
        workingDirectory: String? = nil,
        user: User? = nil,
        network: NetworkMode = .default,
        security: SecurityOptions = .default,
        metadata: OperationMetadata = OperationMetadata()
    ) {
        self.command = command
        self.environment = environment
        self.mounts = mounts
        self.workingDirectory = workingDirectory
        self.user = user
        self.network = network
        self.security = security
        self.metadata = metadata
    }

    public func accept<V: OperationVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Command

/// Represents a command to execute.
///
/// Design rationale:
/// - Preserves shell vs exec form from Dockerfile
/// - Shell form uses default shell with command as string
/// - Exec form bypasses shell for direct execution
public enum Command: Hashable, Sendable {
    /// Shell form: command is passed to shell
    case shell(String)

    /// Exec form: direct execution without shell
    case exec([String])

    /// The command string for display
    public var displayString: String {
        switch self {
        case .shell(let cmd):
            return cmd
        case .exec(let args):
            return args.joined(separator: " ")
        }
    }

    /// Arguments for execution
    public var arguments: [String] {
        switch self {
        case .shell(let cmd):
            return ["/bin/sh", "-c", cmd]
        case .exec(let args):
            return args
        }
    }
}

// MARK: - Environment

/// Environment variables for execution.
///
/// Design rationale:
/// - Preserves order for predictable overwrites
/// - Supports both literal values and build args
/// - Case-sensitive on Linux, case-insensitive on Windows
public struct Environment: Hashable, Sendable {
    public let variables: [(key: String, value: EnvironmentValue)]

    public init(_ variables: [(key: String, value: EnvironmentValue)] = []) {
        self.variables = variables
    }

    public static let empty = Environment()

    /// Get effective environment as dictionary (last value wins)
    public var effectiveEnvironment: [String: String] {
        var result: [String: String] = [:]
        for (key, value) in variables {
            if case .literal(let str) = value {
                result[key] = str
            }
        }
        return result
    }
}

// Custom Hashable conformance for Environment
extension Environment {
    public static func == (lhs: Environment, rhs: Environment) -> Bool {
        guard lhs.variables.count == rhs.variables.count else { return false }
        for (index, (lkey, lvalue)) in lhs.variables.enumerated() {
            let (rkey, rvalue) = rhs.variables[index]
            if lkey != rkey || lvalue != rvalue {
                return false
            }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        for (key, value) in variables {
            hasher.combine(key)
            hasher.combine(value)
        }
    }
}

/// Environment variable value.
public enum EnvironmentValue: Hashable, Sendable {
    /// Literal string value
    case literal(String)

    /// Reference to build argument
    case buildArg(String)

    /// Expansion with default
    case expansion(name: String, default: String?)
}

// MARK: - Mounts

/// Represents a mount in the container.
///
/// Design rationale:
/// - Type-safe mount specifications
/// - Supports all Dockerfile mount types
/// - Extensible for future mount types
public struct Mount: Hashable, Sendable {
    public let type: MountType
    public let target: String?
    public let envTarget: String?
    public let source: MountSource?
    public let options: MountOptions

    public init(
        type: MountType,
        target: String? = nil,
        envTarget: String? = nil,
        source: MountSource? = nil,
        options: MountOptions = MountOptions()
    ) {
        self.type = type
        self.target = target
        self.envTarget = envTarget
        self.source = source
        self.options = options
    }
}

/// Type of mount.
public enum MountType: String, Hashable, Sendable {
    case bind
    case cache
    case tmpfs
    case secret
    case ssh
}

/// Source of mount data.
public enum MountSource: Hashable, Sendable {
    /// Local path
    case local(String)

    /// From another stage
    case stage(StageReference, path: String)

    /// From image
    case image(ImageReference, path: String)

    /// Build context
    case context(String, path: String)

    /// Secret by ID
    case secret(String)

    /// SSH agent socket
    case sshAgent
}

/// Mount options.
public struct MountOptions: Hashable, Sendable {
    public let readOnly: Bool
    public let uid: UInt32?
    public let gid: UInt32?
    public let mode: UInt32?
    public let size: UInt32?  // For tmpfs
    public let sharing: SharingMode?  // For cache mounts
    public let required: Bool?

    public init(
        readOnly: Bool = false,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        mode: UInt32? = nil,
        size: UInt32? = nil,
        sharing: SharingMode? = nil,
        required: Bool? = nil,
    ) {
        self.readOnly = readOnly
        self.uid = uid
        self.gid = gid
        self.mode = mode
        self.size = size
        self.sharing = sharing
        self.required = required
    }
}

// MARK: - User

/// User specification for command execution.
public enum User: Hashable, Sendable {
    /// User by name
    case named(String)

    /// User by UID
    case uid(UInt32)

    /// User and group
    case userGroup(user: String, group: String)

    /// UID and GID
    case uidGid(uid: UInt32, gid: UInt32)
}

// MARK: - Network

/// Network mode for execution.
public enum NetworkMode: String, Hashable, Sendable {
    /// Default network
    case `default`

    /// No network
    case none

    /// Host network
    case host
}

// MARK: - Security

/// Security options for execution.
public struct SecurityOptions: Hashable, Sendable {
    public let privileged: Bool
    public let capabilities: SecurityCapabilities?
    public let seccompProfile: String?
    public let apparmorProfile: String?
    public let noNewPrivileges: Bool

    public init(
        privileged: Bool = false,
        capabilities: SecurityCapabilities? = nil,
        seccompProfile: String? = nil,
        apparmorProfile: String? = nil,
        noNewPrivileges: Bool = true
    ) {
        self.privileged = privileged
        self.capabilities = capabilities
        self.seccompProfile = seccompProfile
        self.apparmorProfile = apparmorProfile
        self.noNewPrivileges = noNewPrivileges
    }

    public static let `default` = SecurityOptions()
}

/// Linux capabilities.
public struct SecurityCapabilities: Hashable, Sendable {
    public let add: Set<String>
    public let drop: Set<String>

    public init(add: Set<String> = [], drop: Set<String> = []) {
        self.add = add
        self.drop = drop
    }
}

// MARK: - Codable

extension ExecOperation: Codable {}
extension Command: Codable {}
extension Environment: Codable {
    private struct EnvVar: Codable {
        let key: String
        let value: EnvironmentValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let envVars = try container.decode([EnvVar].self)
        self.variables = envVars.map { ($0.key, $0.value) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let envVars = variables.map { EnvVar(key: $0.key, value: $0.value) }
        try container.encode(envVars)
    }
}
extension EnvironmentValue: Codable {}
extension Mount: Codable {}
extension MountType: Codable {}
extension MountSource: Codable {}
extension MountOptions: Codable {}
extension User: Codable {}
extension NetworkMode: Codable {}
extension SecurityOptions: Codable {}
extension SecurityCapabilities: Codable {}
