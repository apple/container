//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import Containerization
import ContainerizationError
import Foundation

public struct Bundle: Sendable {
    private static let initfsFilename = "initfs.ext4"
    private static let kernelFilename = "kernel.json"
    private static let kernelBinaryFilename = "kernel.bin"
    private static let containerRootFsBlockFilename = "rootfs.ext4"
    private static let containerRootFsFilename = "rootfs.json"

    static let containerConfigFilename = "config.json"

    /// The path to the bundle.
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public var bootlog: URL {
        self.path.appendingPathComponent("vminitd.log")
    }

    private var containerRootfsBlock: URL {
        self.path.appendingPathComponent(Self.containerRootFsBlockFilename)
    }

    private var containerRootfsConfig: URL {
        self.path.appendingPathComponent(Self.containerRootFsFilename)
    }

    public var containerRootfs: Filesystem {
        get throws {
            let data = try Data(contentsOf: containerRootfsConfig)
            let fs = try JSONDecoder().decode(Filesystem.self, from: data)
            return fs
        }
    }

    /// Return the initial filesystem for a sandbox.
    public var initialFilesystem: Filesystem {
        .block(
            format: "ext4",
            source: self.path.appendingPathComponent(Self.initfsFilename).path,
            destination: "/",
            options: ["ro"]
        )
    }

    public var kernel: Kernel {
        get throws {
            try load(path: self.path.appendingPathComponent(Self.kernelFilename))
        }
    }

    public var configuration: ContainerConfiguration {
        get throws {
            try load(path: self.path.appendingPathComponent(Self.containerConfigFilename))
        }
    }
}

extension Bundle {
    public static func create(
        path: URL,
        initialFilesystem: Filesystem,
        kernel: Kernel,
        containerConfiguration: ContainerConfiguration? = nil
    ) throws -> Bundle {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let kbin = path.appendingPathComponent(Self.kernelBinaryFilename)
        try FileManager.default.copyItem(at: kernel.path, to: kbin)
        var k = kernel
        k.path = kbin
        try write(path.appendingPathComponent(Self.kernelFilename), value: k)

        switch initialFilesystem.type {
        case .block(let fmt, _, _):
            guard fmt == "ext4" else {
                fatalError("ext4 is the only supported format for initial filesystem")
            }
            // when saving the Initial Filesystem to the bundle
            // discard any filesystem information and just persist
            // the block into the Bundle.
            _ = try initialFilesystem.clone(to: path.appendingPathComponent(Self.initfsFilename).path)
        default:
            fatalError("invalid filesystem type for initial filesystem")
        }
        let bundle = Bundle(path: path)
        if let containerConfiguration {
            try bundle.write(filename: Self.containerConfigFilename, value: containerConfiguration)
        }
        return bundle
    }
}

extension Bundle {
    /// Set the value of the configuration for the Bundle.
    public func set(configuration: ContainerConfiguration) throws {
        try write(filename: Self.containerConfigFilename, value: configuration)
    }

    /// Return the full filepath for a named resource in the Bundle.
    public func filePath(for name: String) -> URL {
        path.appendingPathComponent(name)
    }

    public func setContainerRootFs(cloning fs: Filesystem) throws {
        let cloned = try fs.clone(to: self.containerRootfsBlock.absolutePath())
        let fsData = try JSONEncoder().encode(cloned)
        try fsData.write(to: self.containerRootfsConfig)
    }

    /// Delete the bundle and all of the resources contained inside.
    public func delete() throws {
        try FileManager.default.removeItem(at: self.path)
    }

    public func write(filename: String, value: Encodable) throws {
        try Self.write(self.path.appendingPathComponent(filename), value: value)
    }

    private static func write(_ path: URL, value: Encodable) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: path)
    }

    public func load<T>(filename: String) throws -> T where T: Decodable {
        try load(path: self.path.appendingPathComponent(filename))
    }

    private func load<T>(path: URL) throws -> T where T: Decodable {
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
