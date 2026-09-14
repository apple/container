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

import ContainerizationError
import Foundation
import SystemPackage

/// Boot-time configuration for a container machine.
///
/// These values can be modified without recreating the container machine.
/// Changes take effect on the next boot. `nil` values mean
/// "use the container runtime default."
public struct MachineConfig: Codable, Sendable {
    public static let `default`: MachineConfig = try! .init(
        cpus: nil, memory: nil, homeMount: nil, virtualization: nil, kernelPath: nil)

    public static var defaultCPUs: Int {
        max(ProcessInfo.processInfo.processorCount / 2, 4)
    }

    public static var defaultMemory: MemorySize {
        let bytes = max(ProcessInfo.processInfo.physicalMemory / 2, 1024 * 1024 * 1024)
        let gb = bytes / (1024 * 1024 * 1024)
        return try! MemorySize("\(gb)gb")
    }

    public static let defaultHomeMount: HomeMountOption = .rw

    /// Home mount option for the /Users/<name> directory.
    public enum HomeMountOption: String, Sendable, Codable {
        case ro
        case rw
        case none
    }

    /// A user-specified host directory bind-mounted into the container machine.
    ///
    /// Stored as plain absolute paths so this type stays self-contained within
    /// `ContainerPersistence`; it is lifted to a virtiofs share at boot time.
    public struct Mount: Codable, Sendable, Equatable {
        /// Absolute host directory path.
        public let source: String
        /// Absolute mount point inside the container machine.
        public let destination: String
        /// Whether the mount is read-only. `false` means read-write.
        public let readOnly: Bool

        public init(source: String, destination: String, readOnly: Bool) {
            self.source = source
            self.destination = destination
            self.readOnly = readOnly
        }
    }

    /// Number of virtual CPUs.
    public let cpus: Int
    /// Memory in bytes.
    public let memory: MemorySize
    /// Home mount configuration. nil = system default.
    public let homeMount: HomeMountOption
    /// Whether to expose nested virtualization to the container machine.
    public let virtualization: Bool
    /// Optional path to a custom kernel binary. nil falls back to the system default.
    public let kernelPath: FilePath?
    /// Additional host directories bind-mounted into the container machine.
    public let mounts: [Mount]

    private enum CodingKeys: String, CodingKey {
        case cpus
        case memory
        case homeMount
        case virtualization
        case kernelPath
        case mounts
    }

    /// Settable keys and their descriptions, for CLI help text generation.
    public static let settableKeys: [(key: String, valueName: String, description: String)] = [
        ("cpus", "<number>", "Number of virtual CPUs"),
        ("memory", "<size>", "Memory allocation (e.g., 2G, 1G). Default: half of system memory"),
        ("home-mount", "<string>", "User home directory mount option (ro, rw, none). Default: rw"),
        ("virtualization", "<bool>", "Enable nested virtualization (true|false). Requires Apple Silicon M3+ and macOS 15+ and kernel with CONFIG_KVM=y."),
        ("kernel", "<path>", "Path to a custom kernel binary. Empty value resets to the system default."),
    ]

    public init(
        cpus: Int?,
        memory: MemorySize?,
        homeMount: HomeMountOption?,
        virtualization: Bool?,
        kernelPath: FilePath?,
        mounts: [Mount] = []
    ) throws {
        self.cpus = cpus ?? Self.defaultCPUs
        self.memory = memory ?? Self.defaultMemory
        self.homeMount = homeMount ?? Self.defaultHomeMount
        self.virtualization = virtualization ?? false
        self.kernelPath = kernelPath
        self.mounts = mounts

        try self.validate()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let cpus = try container.decodeIfPresent(Int.self, forKey: .cpus)
        let memory = try container.decodeIfPresent(MemorySize.self, forKey: .memory)
        let homeMount = try container.decodeIfPresent(HomeMountOption.self, forKey: .homeMount)
        let virtualization = try container.decodeIfPresent(Bool.self, forKey: .virtualization)
        // FilePath's default Codable conformance encodes its internal SystemChar storage,
        // which the project's ConfigSnapshotDecoder can't handle. Persist as a plain String
        // and lift to FilePath in memory.
        let kernelPath = try container.decodeIfPresent(String.self, forKey: .kernelPath).map { FilePath($0) }
        // Mounts are a per-machine value carried in boot-config.json (plain JSON).
        // The system-wide `[machine]` section is read through ConfigSnapshotDecoder,
        // which cannot represent arrays of structs, so skip the field on that path.
        // Absent in boot configs written before user mounts existed; default to none.
        let mounts: [Mount]
        if decoder is ConfigSnapshotDecoderImpl {
            mounts = []
        } else {
            mounts = try container.decodeIfPresent([Mount].self, forKey: .mounts) ?? []
        }

        try self.init(
            cpus: cpus,
            memory: memory,
            homeMount: homeMount,
            virtualization: virtualization,
            kernelPath: kernelPath,
            mounts: mounts)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cpus, forKey: .cpus)
        try container.encode(memory, forKey: .memory)
        try container.encode(homeMount, forKey: .homeMount)
        try container.encode(virtualization, forKey: .virtualization)
        try container.encodeIfPresent(kernelPath?.string, forKey: .kernelPath)
        if !mounts.isEmpty {
            try container.encode(mounts, forKey: .mounts)
        }
    }

    private func validate() throws {
        guard self.cpus > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid CPU count '\(self.cpus)'. Must be a positive integer (e.g., 4)."
            )
        }

        guard self.memory.toUInt64(unit: .bytes) >= 1024 * 1024 * 1024 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid memory value '\(self.memory)'. Must be greater than 1gb."
            )
        }

        var seenDestinations = Set<String>()
        for mount in self.mounts {
            guard seenDestinations.insert(mount.destination).inserted else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "duplicate mount destination '\(mount.destination)'"
                )
            }
        }
    }
}

extension MachineConfig {
    /// Generate a help discussion string listing all settable keys.
    public static func helpText() -> String {
        settableKeys.map { entry in
            let label = "\(entry.key)=\(entry.valueName)"
            let padding = String(repeating: " ", count: max(1, 24 - label.count))
            return "\(label)\(padding)\(entry.description)"
        }.joined(separator: "\n")
    }

    /// Create a new MachineConfig from `self`, applying fields defined in `kwargs`.
    /// Mount specifications are supplied separately because they are a repeatable
    /// list rather than a scalar `key=value` setting. `nil` leaves mounts unchanged.
    /// This function is used in both `machine create` and `machine set`
    public func with(_ kwargs: [String: String], mounts mountSpecs: [String]? = nil) throws -> MachineConfig {
        let validKeys = Set(Self.settableKeys.map(\.key))
        let unknownKeys = Set(kwargs.keys).subtracting(validKeys)
        guard unknownKeys.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "unknown fields '\(unknownKeys.joined(separator: ", "))'. Valid: \(validKeys.joined(separator: ", "))")
        }

        let cpus = try kwargs["cpus"].map { try Self.parseInt($0, for: "cpus") }
        let memory = try kwargs["memory"].map { try MemorySize($0) }
        let homeMount = try kwargs["home-mount"].map { try Self.parseHomeMount($0) }
        let virtualization = try kwargs["virtualization"].map { try Self.parseBool($0, for: "virtualization") }
        // Empty string explicitly clears the kernel override; absent key leaves it unchanged.
        let kernelPath: FilePath?
        if let raw = kwargs["kernel"] {
            kernelPath = raw.isEmpty ? nil : FilePath(raw)
        } else {
            kernelPath = self.kernelPath
        }

        let mounts = try mountSpecs.map { try $0.map { try Self.parseMount($0) } }

        return try .init(
            cpus: cpus ?? self.cpus,
            memory: memory ?? self.memory,
            homeMount: homeMount ?? self.homeMount,
            virtualization: virtualization ?? self.virtualization,
            kernelPath: kernelPath,
            mounts: mounts ?? self.mounts
        )
    }

    /// Parse and validate a CPU count from user input.
    private static func parseInt(_ value: String, for key: String) throws -> Int {
        guard let num = Int(value) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "failed to parse \(value) for \(key)"
            )
        }
        return num
    }

    /// Parse and validate a home mount option from user input.
    private static func parseHomeMount(_ value: String) throws -> MachineConfig.HomeMountOption {
        guard let opt = MachineConfig.HomeMountOption(rawValue: value) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid home mount option '\(value)'. Valid options: ro, rw, none"
            )
        }
        return opt
    }

    /// Parse a `host:guest[:ro|rw]` bind-mount specification into a `Mount`.
    ///
    /// The host path must be an existing directory; it and the guest path are
    /// resolved to absolute paths. The optional third field selects the access
    /// mode and defaults to read-write.
    public static func parseMount(_ value: String) throws -> Mount {
        let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid mount '\(value)'. Expected 'host:guest' or 'host:guest:ro|rw'"
            )
        }

        let readOnly: Bool
        if parts.count == 3 {
            switch parts[2] {
            case "ro": readOnly = true
            case "rw": readOnly = false
            default:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "invalid mount mode '\(parts[2])' in '\(value)'. Valid options: ro, rw"
                )
            }
        } else {
            readOnly = false
        }

        let source = URL(fileURLWithPath: parts[0]).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory) else {
            throw ContainerizationError(.invalidArgument, message: "mount source '\(parts[0])' does not exist")
        }
        guard isDirectory.boolValue else {
            throw ContainerizationError(.invalidArgument, message: "mount source '\(parts[0])' is not a directory")
        }

        let destination = parts[1]
        guard destination.hasPrefix("/") else {
            throw ContainerizationError(
                .invalidArgument,
                message: "mount destination '\(destination)' must be an absolute path"
            )
        }

        return Mount(source: source, destination: destination, readOnly: readOnly)
    }

    /// Parse a boolean setting accepting only "true" or "false".
    private static func parseBool(_ value: String, for key: String) throws -> Bool {
        guard let result = Parsers.parseBool(string: value) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid value '\(value)' for \(key). Expected 'true' or 'false'."
            )
        }
        return result
    }
}

extension MachineConfig {
    /// Resolves the user-supplied kernel path to absolute and confirms it points to a
    /// readable, non-empty regular file. Used at create, set, and boot time.
    public static func validateKernelPath(_ path: String) throws -> FilePath {
        let absolute = URL(fileURLWithPath: path).path
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: absolute, isDirectory: &isDirectory) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel binary not found at '\(absolute)'"
            )
        }
        guard !isDirectory.boolValue else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel path '\(absolute)' is a directory, expected a file"
            )
        }
        guard fm.isReadableFile(atPath: absolute) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel binary at '\(absolute)' is not readable"
            )
        }
        let attrs = try fm.attributesOfItem(atPath: absolute)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel binary at '\(absolute)' is empty"
            )
        }
        return FilePath(absolute)
    }
}
