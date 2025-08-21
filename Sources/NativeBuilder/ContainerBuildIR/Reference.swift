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

/// A reference to a container image.
///
/// Design rationale:
/// - Supports all common reference formats (registry, tag, digest)
/// - Validates references on creation to catch errors early
/// - Immutable to ensure references remain valid
/// - Follows Docker/OCI reference specification
public struct ImageReference: Hashable, Sendable {
    /// Registry host (e.g., "docker.io", "ghcr.io")
    public let registry: String?

    /// Repository path (e.g., "library/ubuntu", "myorg/myapp")
    public let repository: String

    /// Tag (e.g., "latest", "v1.2.3")
    public let tag: String?

    /// Digest for content-addressed reference
    public let digest: Digest?

    /// Create an image reference
    /// - Note: Must have either tag or digest (or both)
    public init(
        registry: String? = nil,
        repository: String,
        tag: String? = nil,
        digest: Digest? = nil
    ) throws {
        guard tag != nil || digest != nil else {
            throw ReferenceError.missingTagOrDigest
        }

        // Validate repository format
        guard Self.isValidRepository(repository) else {
            throw ReferenceError.invalidRepository(repository)
        }

        // Validate registry if provided
        if let registry = registry {
            guard Self.isValidRegistry(registry) else {
                throw ReferenceError.invalidRegistry(registry)
            }
        }

        self.registry = registry
        self.repository = repository
        self.tag = tag
        self.digest = digest
    }

    /// Parse an image reference string (e.g., "ubuntu:20.04", "ghcr.io/myorg/app@sha256:...")
    public init?(parsing string: String) {
        // Handle digest references (containing @)
        let digestSplit = string.split(separator: "@", maxSplits: 1)
        let beforeDigest = String(digestSplit[0])
        let digest: Digest?
        if digestSplit.count == 2 {
            let digestString = String(digestSplit[1])
            // If it starts with sha256:, it's already in the right format
            // Otherwise prepend sha256:
            let fullDigestString = digestString.hasPrefix("sha256:") ? digestString : "sha256:\(digestString)"
            guard let d = try? Digest(parsing: fullDigestString) else { return nil }
            digest = d
        } else {
            digest = nil
        }

        // First, determine if we have a registry by looking at the first component
        let pathComponents = beforeDigest.split(separator: "/")

        let registry: String?
        let repoAndTag: String

        if pathComponents.count >= 2 {
            let firstComponent = String(pathComponents[0])
            // Check if first component looks like a registry
            // It's a registry if it contains a dot (domain) or colon (port) or is "localhost"
            if firstComponent.contains(".") || firstComponent.contains(":") || firstComponent == "localhost" {
                registry = firstComponent
                repoAndTag = pathComponents.dropFirst().joined(separator: "/")
            } else {
                registry = nil
                repoAndTag = beforeDigest
            }
        } else {
            registry = nil
            repoAndTag = beforeDigest
        }

        // Now handle tag in the repository part
        let tagSplit = repoAndTag.split(separator: ":", maxSplits: 1)
        let repository = String(tagSplit[0])
        let tag: String? = tagSplit.count == 2 ? String(tagSplit[1]) : nil

        do {
            try self.init(
                registry: registry,
                repository: repository,
                tag: tag ?? (digest == nil ? "latest" : nil),
                digest: digest
            )
        } catch {
            return nil
        }
    }

    /// Full reference string
    public var stringValue: String {
        var result = ""

        if let registry = registry {
            result += registry + "/"
        }

        result += repository

        if let tag = tag {
            result += ":" + tag
        }

        if let digest = digest {
            result += "@" + digest.stringValue
        }

        return result
    }

    /// Reference without registry (for local use)
    public var localReference: String {
        var result = repository

        if let tag = tag {
            result += ":" + tag
        }

        if let digest = digest {
            result += "@" + digest.stringValue
        }

        return result
    }

    // MARK: - Validation

    private static func isValidRepository(_ repo: String) -> Bool {
        // Basic validation - can be enhanced
        !repo.isEmpty && repo.allSatisfy { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private static func isValidRegistry(_ registry: String) -> Bool {
        // Must contain a dot or colon (to distinguish from repository)
        registry.contains(".") || registry.contains(":")
    }

    private static func looksLikeRegistry(_ component: String) -> Bool {
        // Contains dot (domain) or is "localhost"
        // Note: Don't check for colon here as it could be a tag separator
        component.contains(".") || component == "localhost"
    }
}

/// A reference to a build stage.
///
/// Design rationale:
/// - Supports both named stages and index-based references
/// - Type-safe to prevent mixing stage and image references
/// - Lightweight for efficient graph operations
public enum StageReference: Hashable, Sendable {
    /// Reference by stage name (FROM ubuntu AS builder -> "builder")
    case named(String)

    /// Reference by stage index (0-based)
    case index(Int)

    /// The previous stage (used for implicit references)
    case previous

    public var stringValue: String {
        switch self {
        case .named(let name):
            return name
        case .index(let idx):
            return String(idx)
        case .previous:
            return "<previous>"
        }
    }
}

// MARK: - Errors

public enum ReferenceError: LocalizedError {
    case missingTagOrDigest
    case invalidRepository(String)
    case invalidRegistry(String)
    case invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case .missingTagOrDigest:
            return "Image reference must have either a tag or digest"
        case .invalidRepository(let repo):
            return "Invalid repository format: '\(repo)'"
        case .invalidRegistry(let registry):
            return "Invalid registry format: '\(registry)'"
        case .invalidFormat(let string):
            return "Invalid reference format: '\(string)'"
        }
    }
}

// MARK: - Codable

extension ImageReference: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let parsed = ImageReference(parsing: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid image reference: \(string)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

extension StageReference: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let index = try? container.decode(Int.self) {
            self = .index(index)
        } else if let name = try? container.decode(String.self) {
            if name == "<previous>" {
                self = .previous
            } else {
                self = .named(name)
            }
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid stage reference")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .named(let name):
            try container.encode(name)
        case .index(let idx):
            try container.encode(idx)
        case .previous:
            try container.encode("<previous>")
        }
    }
}

// MARK: - CustomStringConvertible

extension ImageReference: CustomStringConvertible {
    public var description: String { stringValue }
}

extension StageReference: CustomStringConvertible {
    public var description: String { stringValue }
}
