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

import Foundation
import SystemPackage

/// Represents a socket that should be published from container to host.
public struct PublishSocket: Sendable, Codable {
    /// The path to the socket in the container.
    public var containerPath: FilePath

    /// The path where the socket should appear on the host.
    public var hostPath: FilePath

    /// File permissions for the socket on the host.
    public var permissions: FilePermissions?

    public init(
        containerPath: FilePath,
        hostPath: FilePath,
        permissions: FilePermissions? = nil
    ) {
        self.containerPath = containerPath
        self.hostPath = hostPath
        self.permissions = permissions
    }

    private enum CodingKeys: String, CodingKey {
        case containerPath
        case hostPath
        case permissions
    }

    /// Encode paths as file-URL absolute strings (e.g. `"file:///var/run/docker.sock"`).
    ///
    /// These fields were previously typed `URL`; `JSONEncoder` special-cases
    /// `URL` to emit `absoluteString`. `FilePath`'s synthesized `Codable`
    /// would instead emit a keyed container (`{"_storage": "..."}`), changing
    /// the on-disk and XPC wire format. We therefore encode each path as the
    /// equivalent `URL.absoluteString` so the byte form remains compatible
    /// with persisted bundles and any readers (e.g. an older service binary)
    /// that still decode these fields as `URL`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.encodePath(containerPath), forKey: .containerPath)
        try container.encode(Self.encodePath(hostPath), forKey: .hostPath)
        try container.encodeIfPresent(permissions, forKey: .permissions)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.containerPath = try Self.decodePath(from: container, forKey: .containerPath)
        self.hostPath = try Self.decodePath(from: container, forKey: .hostPath)
        self.permissions = try container.decodeIfPresent(FilePermissions.self, forKey: .permissions)
    }

    /// Encode a `FilePath` as a file-URL `absoluteString` to match the prior
    /// `URL`-typed wire format byte-for-byte.
    private static func encodePath(_ path: FilePath) -> String {
        URL(filePath: path.string).absoluteString
    }

    /// Decode a `FilePath` from either the canonical file-URL form
    /// (e.g. `"file:///foo"`) emitted by `encodePath(_:)` and the legacy
    /// `URL`-typed wire format, or a plain absolute path string. Throws
    /// `DecodingError.dataCorrupted` on malformed, empty, or non-absolute
    /// inputs so corrupt persisted state fails loudly rather than silently
    /// producing an invalid socket path.
    private static func decodePath(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> FilePath {
        let raw = try container.decode(String.self, forKey: key)

        let path: String
        if raw.hasPrefix("file:") {
            guard let url = URL(string: raw), url.isFileURL else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "malformed file URL: \(raw)"
                )
            }
            if let host = url.host(), !host.isEmpty, host != "localhost" {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "file URL host must be empty or 'localhost': \(raw)"
                )
            }
            path = url.path(percentEncoded: false)
        } else {
            path = raw
        }

        guard path.hasPrefix("/") else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "socket path must be absolute: \(raw)"
            )
        }

        return FilePath(path)
    }
}
