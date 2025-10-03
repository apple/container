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

import Foundation

/// Options to pass to a mount call.
public typealias MountOptions = [String]

extension MountOptions {
    /// Returns true if the Filesystem should be consumed as read-only.
    public var readonly: Bool {
        self.contains("ro")
    }
}

/// A host filesystem that will be attached to the sandbox for use.
///
/// A filesystem will be mounted automatically when starting the sandbox
/// or container.
public struct Filesystem: Sendable, Codable {
    /// Type of caching to perform at the host level.
    public enum CacheMode: Sendable, Codable {
        case on
        case off
        case auto
    }

    /// Sync mode to perform at the host level.
    public enum SyncMode: Sendable, Codable {
        case full
        case fsync
        case nosync
    }

    /// The type of filesystem attachment for the sandbox.
    public enum FSType: Sendable, Codable, Equatable {
        package enum VirtiofsType: String, Sendable, Codable, Equatable {
            // This is a virtiofs share for the rootfs of a sandbox.
            case rootfs
            // Data share. This is what all virtiofs shares for anything besides
            // the rootfs for a sandbox will be.
            case data
        }

        case block(format: String, cache: CacheMode, sync: SyncMode)
        case volume(name: String, format: String, cache: CacheMode, sync: SyncMode)
        case virtiofs
        case tmpfs
    }

    /// Type of the filesystem.
    public var type: FSType
    /// Source of the filesystem.
    public var source: String
    /// Destination where the filesystem should be mounted.
    public var destination: String
    /// Mount options applied when mounting the filesystem.
    public var options: MountOptions

    public init() {
        self.type = .tmpfs
        self.source = ""
        self.destination = ""
        self.options = []
    }

    public init(type: FSType, source: String, destination: String, options: MountOptions) {
        self.type = type
        self.source = source
        self.destination = destination
        self.options = options
    }

    /// A block based filesystem.
    public static func block(
        format: String, source: String, destination: String, options: MountOptions, cache: CacheMode = .auto,
        sync: SyncMode = .full
    ) -> Filesystem {
        .init(
            type: .block(format: format, cache: cache, sync: sync),
            source: URL(fileURLWithPath: source).absolutePath(),
            destination: destination,
            options: options
        )
    }

    /// A named volume filesystem.
    public static func volume(
        name: String, format: String, source: String, destination: String, options: MountOptions,
        cache: CacheMode = .auto, sync: SyncMode = .full
    ) -> Filesystem {
        .init(
            type: .volume(name: name, format: format, cache: cache, sync: sync),
            source: URL(fileURLWithPath: source).absolutePath(),
            destination: destination,
            options: options
        )
    }

    /// A vritiofs backed filesystem providing a directory.
    public static func virtiofs(source: String, destination: String, options: MountOptions) -> Filesystem {
        .init(
            type: .virtiofs,
            source: URL(fileURLWithPath: source).absolutePath(),
            destination: destination,
            options: options
        )
    }

    public static func tmpfs(destination: String, options: MountOptions) -> Filesystem {
        .init(
            type: .tmpfs,
            source: "tmpfs",
            destination: destination,
            options: options
        )
    }

    /// Returns true if the Filesystem is backed by a block device.
    public var isBlock: Bool {
        switch type {
        case .block(_, _, _): true
        case .volume(_, _, _, _): true
        default: false
        }
    }

    /// Returns true if the Filesystem is a named volume.
    public var isVolume: Bool {
        switch type {
        case .volume(_, _, _, _): true
        default: false
        }
    }

    /// Returns the volume name if this is a volume filesystem, nil otherwise.
    public var volumeName: String? {
        switch type {
        case .volume(let name, _, _, _): name
        default: nil
        }
    }

    /// Returns true if the Filesystem is backed by a in-memory mount type.
    public var isTmpfs: Bool {
        switch type {
        case .tmpfs: true
        default: false
        }
    }

    /// Returns true if the Filesystem is backed by virtioFS.
    public var isVirtiofs: Bool {
        switch type {
        case .virtiofs: true
        default: false
        }
    }

    /// Clone the Filesystem to the provided path.
    ///
    /// This uses `clonefile` to provide a copy-on-write copy of the Filesystem.
    public func clone(to: String) throws -> Self {
        let fm = FileManager.default
        let src = self.source
        try fm.copyItem(atPath: src, toPath: to)
        return .init(type: self.type, source: to, destination: self.destination, options: self.options)
    }
}
