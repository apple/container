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

import ContainerBuildIR
import ContainerBuildSnapshotter
import ContainerizationOCI
import Foundation

// MARK: - Cache Manifest Types

/// OCI-compliant cache manifest stored in ContentStore
struct CacheManifest: Codable, Sendable {
    let schemaVersion: Int
    let mediaType: String
    let config: CacheConfig
    let annotations: [String: String]
    let subject: Descriptor?

    /// Snapshot embedded directly in manifest
    let snapshot: Snapshot?

    /// Environment changes embedded directly in manifest
    let environmentChanges: [String: EnvironmentValue]

    /// Metadata changes embedded directly in manifest
    let metadataChanges: [String: String]

    static let currentSchemaVersion = 5  // Incremented for direct Snapshot storage
    static let manifestMediaType = "application/vnd.container-build.cache.manifest.v5+json"

    init(
        schemaVersion: Int = CacheManifest.currentSchemaVersion,
        mediaType: String = CacheManifest.manifestMediaType,
        config: CacheConfig,
        annotations: [String: String] = [:],
        subject: Descriptor? = nil,
        snapshot: Snapshot? = nil,
        environmentChanges: [String: EnvironmentValue] = [:],
        metadataChanges: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.mediaType = mediaType
        self.config = config
        self.annotations = annotations
        self.subject = subject
        self.snapshot = snapshot
        self.environmentChanges = environmentChanges
        self.metadataChanges = metadataChanges
    }
}

/// Cache configuration embedded in manifest
struct CacheConfig: Codable, Sendable {
    let cacheKey: SerializedCacheKey
    let operationType: String
    let platform: Platform
    let buildVersion: String
    let createdAt: Date

    init(
        cacheKey: SerializedCacheKey,
        operationType: String,
        platform: Platform,
        buildVersion: String,
        createdAt: Date = Date()
    ) {
        self.cacheKey = cacheKey
        self.operationType = operationType
        self.platform = platform
        self.buildVersion = buildVersion
        self.createdAt = createdAt
    }
}

/// Serializable version of CacheKey for storage
struct SerializedCacheKey: Codable, Sendable {
    let operationDigest: String
    let inputDigests: [String]
    let platform: PlatformData

    struct PlatformData: Codable, Sendable {
        let os: String
        let architecture: String
        let variant: String?
        let osVersion: String?
        let osFeatures: [String]?
    }

    init(from key: CacheKey) {
        self.operationDigest = key.operationDigest.stringValue
        self.inputDigests = key.inputDigests.map { $0.stringValue }
        self.platform = PlatformData(
            os: key.platform.os,
            architecture: key.platform.architecture,
            variant: key.platform.variant,
            osVersion: key.platform.osVersion,
            osFeatures: key.platform.osFeatures.map { Array($0) }
        )
    }
}

// MARK: - Manifest Extensions

extension CacheManifest {
    /// Create a manifest with subject reference (for linking to base images)
    func withSubject(_ subject: Descriptor) -> CacheManifest {
        CacheManifest(
            schemaVersion: schemaVersion,
            mediaType: mediaType,
            config: config,
            annotations: annotations,
            subject: subject,
            snapshot: snapshot,
            environmentChanges: environmentChanges,
            metadataChanges: metadataChanges
        )
    }

    /// Add or update annotation
    func withAnnotation(key: String, value: String) -> CacheManifest {
        var newAnnotations = annotations
        newAnnotations[key] = value

        return CacheManifest(
            schemaVersion: schemaVersion,
            mediaType: mediaType,
            config: config,
            annotations: newAnnotations,
            subject: subject,
            snapshot: snapshot,
            environmentChanges: environmentChanges,
            metadataChanges: metadataChanges
        )
    }

    /// Add or update environment changes
    func withEnvironmentChanges(_ changes: [String: EnvironmentValue]) -> CacheManifest {
        var newEnvironmentChanges = environmentChanges
        for (key, value) in changes {
            newEnvironmentChanges[key] = value
        }

        return CacheManifest(
            schemaVersion: schemaVersion,
            mediaType: mediaType,
            config: config,
            annotations: annotations,
            subject: subject,
            snapshot: snapshot,
            environmentChanges: newEnvironmentChanges,
            metadataChanges: metadataChanges
        )
    }

    /// Add or update metadata changes
    func withMetadataChanges(_ changes: [String: String]) -> CacheManifest {
        var newMetadataChanges = metadataChanges
        for (key, value) in changes {
            newMetadataChanges[key] = value
        }

        return CacheManifest(
            schemaVersion: schemaVersion,
            mediaType: mediaType,
            config: config,
            annotations: annotations,
            subject: subject,
            snapshot: snapshot,
            environmentChanges: environmentChanges,
            metadataChanges: newMetadataChanges
        )
    }

    /// Check if manifest has a snapshot
    var hasSnapshot: Bool {
        snapshot != nil
    }

    /// Check if manifest has environment changes
    var hasEnvironmentChanges: Bool {
        !environmentChanges.isEmpty
    }

    /// Check if manifest has metadata changes
    var hasMetadataChanges: Bool {
        !metadataChanges.isEmpty
    }

    /// Set or update the snapshot
    func withSnapshot(_ snapshot: Snapshot) -> CacheManifest {
        CacheManifest(
            schemaVersion: schemaVersion,
            mediaType: mediaType,
            config: config,
            annotations: annotations,
            subject: subject,
            snapshot: snapshot,
            environmentChanges: environmentChanges,
            metadataChanges: metadataChanges
        )
    }

    /// Create a manifest with combined snapshot, environment and metadata changes
    func withChanges(
        snapshot: Snapshot? = nil,
        environment: [String: EnvironmentValue] = [:],
        metadata: [String: String] = [:]
    ) -> CacheManifest {
        var newEnvironmentChanges = environmentChanges
        var newMetadataChanges = metadataChanges

        for (key, value) in environment {
            newEnvironmentChanges[key] = value
        }

        for (key, value) in metadata {
            newMetadataChanges[key] = value
        }

        return CacheManifest(
            schemaVersion: schemaVersion,
            mediaType: mediaType,
            config: config,
            annotations: annotations,
            subject: subject,
            snapshot: snapshot ?? self.snapshot,
            environmentChanges: newEnvironmentChanges,
            metadataChanges: newMetadataChanges
        )
    }
}

// MARK: - Descriptor Extensions

extension Descriptor {
    /// Create a descriptor for cache content
    static func forCacheContent(
        mediaType: String,
        digest: String,
        size: Int64,
        compressed: Bool = false,
        annotations: [String: String]? = nil
    ) -> Descriptor {
        var finalMediaType = mediaType
        if compressed && !mediaType.contains("+") {
            // Detect compression from annotations if not in media type
            if let compressionType = annotations?["com.apple.container-build.compression"] {
                finalMediaType += "+\(compressionType)"
            }
        }

        return Descriptor(
            mediaType: finalMediaType,
            digest: digest,
            size: size,
            urls: nil,
            annotations: annotations,
            platform: nil
        )
    }
}
