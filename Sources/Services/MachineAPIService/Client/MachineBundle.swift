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
import ContainerResource
import ContainerizationError
import Foundation
import SystemPackage

public struct MachineBundle: Sendable {
    private static let rootfsBlockFile = FilePath.Component("rootfs.ext4")
    private static let rootfsFile = FilePath.Component("rootfs.json")
    private static let configFile = FilePath.Component("config.json")
    private static let userSetupFile = FilePath.Component("create-user.sh")
    private static let bootLogFile = FilePath.Component("vminitd.log")
    private static let stdioLogFile = FilePath.Component("stdio.log")

    public static let sbinDirectory = FilePath.Component("sbin.machine")
    public static let initFile = FilePath.Component("init")
    public static let initializedFile = FilePath.Component("machine.initialized")
    public static let bootConfigFile = FilePath.Component("boot-config.json")

    /// The path to the bundle
    public let path: FilePath

    public init(path: FilePath) {
        self.path = path
    }

    private var machineRootfsBlock: FilePath {
        self.path.appending(Self.rootfsBlockFile)
    }

    private var machineRootfsConfig: FilePath {
        self.path.appending(Self.rootfsFile)
    }

    public var bootLog: FilePath {
        self.path.appending(Self.bootLogFile)
    }

    public var stdioLog: FilePath {
        self.path.appending(Self.stdioLogFile)
    }

    public var initialized: Bool {
        let hasOne = try? String(contentsOf: URL(filePath: self.path.appending(Self.initializedFile).string), encoding: .utf8).hasPrefix("1")
        return hasOne ?? false
    }

    public var machineRootfs: Filesystem {
        get throws {
            let data = try Data(contentsOf: URL(filePath: machineRootfsConfig.string))
            let fs = try JSONDecoder().decode(Filesystem.self, from: data)
            return fs
        }
    }

    private var persistedConfig: PersistedMachineConfig {
        get throws {
            let configPath = self.path.appending(Self.configFile)
            let data = try Data(contentsOf: URL(filePath: configPath.string))
            if let wrapper = try? JSONDecoder().decode(PersistedMachineConfig.self, from: data) {
                return wrapper
            }
            let config = try JSONDecoder().decode(MachineConfiguration.self, from: data)
            return PersistedMachineConfig(configuration: config, createdDate: nil)
        }
    }

    public var configuration: MachineConfiguration {
        get throws {
            try persistedConfig.configuration
        }
    }

    public var createdDate: Date? {
        get throws {
            try persistedConfig.createdDate
        }
    }

    public var diskSize: UInt64? {
        let values = try? URL(filePath: machineRootfsBlock.string).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        guard let allocated = values?.totalFileAllocatedSize else { return nil }
        return UInt64(allocated)
    }

    public var bootConfig: MachineConfig {
        get throws {
            try load(filename: Self.bootConfigFile)
        }
    }
}

/// Metadata from an OCI artifact or in-image file that describes how a container machine
/// should be configured (shell, user creation script, etc.).
public struct MachineResources: Sendable, Codable, Equatable {
    /// The media type for container machine configuration artifacts.
    public static let configMediaType = "application/vnd.apple.container.machine.config.v1+json"

    /// The media type for container machine user setup scripts.
    public static let setupScriptMediaType = "application/vnd.apple.container.machine.setup.v1+sh"

    public var schemaVersion: Int
    public var shell: String?
    public var setupScript: String?

    public init(schemaVersion: Int = 1, shell: String? = nil, setupScript: String? = nil) {
        self.schemaVersion = schemaVersion
        self.shell = shell
        self.setupScript = setupScript
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.shell = try container.decodeIfPresent(String.self, forKey: .shell)
        self.setupScript = try container.decodeIfPresent(String.self, forKey: .setupScript)
    }
}

extension MachineBundle {
    public static func create(
        path: FilePath,
        machineConfiguration: MachineConfiguration,
        resourceRoot: FilePath,
        resources: MachineResources?,
        bootConfig: MachineConfig,
    ) throws -> MachineBundle {
        let fm = FileManager.default

        try fm.createDirectory(atPath: path.string, withIntermediateDirectories: true)
        let bundle = MachineBundle(path: path)

        let persisted = PersistedMachineConfig(configuration: machineConfiguration, createdDate: Date())
        try bundle.write(filename: Self.configFile, value: persisted)
        try bundle.write(filename: Self.bootConfigFile, value: bootConfig)

        let sbin = path.appending(sbinDirectory)
        let initPath = sbin.appending(initFile)
        let setupScriptPath = sbin.appending(userSetupFile)
        let initializedPath = path.appending(initializedFile)

        try fm.createDirectory(atPath: sbin.string, withIntermediateDirectories: true)
        try fm.copyItem(atPath: resourceRoot.appending(initFile).string, toPath: initPath.string)

        if let setupScript = resources?.setupScript {
            try setupScript.write(toFile: setupScriptPath.string, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: setupScriptPath.string)
        } else {
            try fm.copyItem(atPath: resourceRoot.appending(userSetupFile).string, toPath: setupScriptPath.string)
        }

        guard fm.createFile(atPath: initializedPath.string, contents: "".data(using: .utf8)) else {
            throw ContainerizationError(.internalError, message: "failed to create \(initializedPath.string)")
        }

        return bundle
    }

    public static func sync(path: FilePath, resourceRoot: FilePath) throws {
        let fm = FileManager.default

        try fm.createDirectory(atPath: path.string, withIntermediateDirectories: true)

        let sbin = path.appending(sbinDirectory)
        let initPath = sbin.appending(initFile)
        let setupScriptPath = sbin.appending(userSetupFile)
        let initializedPath = path.appending(initializedFile)

        try fm.createDirectory(atPath: sbin.string, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: setupScriptPath.string) {
            try fm.copyItem(atPath: resourceRoot.appending(userSetupFile).string, toPath: setupScriptPath.string)
        }

        if fm.fileExists(atPath: initPath.string) {
            try fm.removeItem(atPath: initPath.string)
        }
        try fm.copyItem(atPath: resourceRoot.appending(initFile).string, toPath: initPath.string)

        if !fm.fileExists(atPath: initializedPath.string) {
            guard fm.createFile(atPath: initializedPath.string, contents: "".data(using: .utf8)) else {
                throw ContainerizationError(.internalError, message: "failed to create \(initializedPath.string)")
            }
        }
    }
}

extension MachineBundle {
    /// Set the value of the configuration for the Bundle.
    public func set(configuration: MachineConfiguration) throws {
        let existing = try? self.persistedConfig
        let persisted = PersistedMachineConfig(configuration: configuration, createdDate: existing?.createdDate)
        try write(filename: Self.configFile, value: persisted)
    }

    /// Set the boot-time configuration for the bundle.
    public func set(bootConfig: MachineConfig) throws {
        try write(filename: Self.bootConfigFile, value: bootConfig)
    }

    /// Return the full filepath for a named resource in the Bundle.
    public func filePath(for name: FilePath.Component) -> FilePath {
        path.appending(name)
    }

    public func setMachineRootFs(cloning fs: Filesystem, readonly: Bool = false) throws {
        var mutableFs = fs
        if readonly && !mutableFs.options.contains("ro") {
            mutableFs.options.append("ro")
        }
        let cloned = try mutableFs.clone(to: self.machineRootfsBlock.string)
        let fsData = try JSONEncoder().encode(cloned)
        try fsData.write(to: URL(filePath: self.machineRootfsConfig.string), options: .atomic)
    }

    /// Delete the bundle and all of the resources contained inside.
    public func delete() throws {
        try FileManager.default.removeItem(atPath: self.path.string)
    }

    public func write(filename: FilePath.Component, value: Encodable) throws {
        try Self.write(self.path.appending(filename), value: value)
    }

    private static func write(_ path: FilePath, value: Encodable) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: URL(filePath: path.string), options: .atomic)
    }

    public func load<T>(filename: FilePath.Component) throws -> T where T: Decodable {
        try load(path: self.path.appending(filename))
    }

    private func load<T>(path: FilePath) throws -> T where T: Decodable {
        let data = try Data(contentsOf: URL(filePath: path.string))
        return try JSONDecoder().decode(T.self, from: data)
    }
}

struct PersistedMachineConfig: Codable, Sendable {
    var configuration: MachineConfiguration
    var createdDate: Date?
}
