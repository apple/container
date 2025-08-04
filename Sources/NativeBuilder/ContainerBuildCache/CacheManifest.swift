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
import ContainerizationOCI
import Foundation

// MARK: - Cache Manifest Types

/// OCI-compliant cache manifest stored in ContentStore
struct CacheManifest: Codable, Sendable {
    let schemaVersion: Int
    let mediaType: String
    let config: CacheConfig
    let layers: [CacheLayer]
    let annotations: [String: String]
    let subject: Descriptor?

    static let currentSchemaVersion = 2
    static let manifestMediaType = "application/vnd.container-build.cache.manifest.v2+json"

    init(
        schemaVersion: Int = CacheManifest.currentSchemaVersion,
        mediaType: String = CacheManifest.manifestMediaType,
        config: CacheConfig,
        layers: [CacheLayer],
        annotations: [String: String] = [:],
        subject: Descriptor? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.mediaType = mediaType
        self.config = config
        self.layers = layers
        self.annotations = annotations
        self.subject = subject
    }

    func allContentDigests() -> [String] {
        layers.map { $0.descriptor.digest }
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

/// Cache layer representing a component of the cached result
struct CacheLayer: Codable, Sendable {
    let descriptor: Descriptor
    let type: LayerType

    enum LayerType: String, Codable, Sendable {
        case snapshot = "snapshot"
        case environment = "environment"
        case metadata = "metadata"
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
            layers: layers,
            annotations: annotations,
            subject: subject
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
            layers: layers,
            annotations: newAnnotations,
            subject: subject
        )
    }

    /// Get total size of all layers
    var totalSize: Int64 {
        layers.reduce(0) { $0 + $1.descriptor.size }
    }

    /// Check if manifest is compressed
    var isCompressed: Bool {
        layers.contains { layer in
            layer.descriptor.mediaType.contains("gzip") || layer.descriptor.mediaType.contains("zstd") || layer.descriptor.mediaType.contains("lz4")
        }
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
