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

import ContainerizationOCI
import Foundation

/// An image resource, representing an OCI image managed by the system.
///
/// `ImageResource` conforms to `ManagedResource` and wraps the image's
/// ``ImageDescription`` (its reference and index descriptor) alongside the
/// resolved index descriptor and the per-platform variants that make up the
/// image.
public struct ImageResource: ManagedResource {
    /// A single platform-specific variant of an image.
    public struct Variant: Sendable, Codable {
        /// The platform this variant targets.
        public let platform: Platform
        /// The digest of this variant's manifest.
        public let digest: String
        /// The total size of this variant in bytes.
        public let size: Int64
        /// The OCI image config for this variant.
        public let config: ContainerizationOCI.Image

        public init(platform: Platform, digest: String, size: Int64, config: ContainerizationOCI.Image) {
            self.platform = platform
            self.digest = digest
            self.size = size
            self.config = config
        }
    }

    /// Already-resolved OCI content for a single platform manifest, used as
    /// input when building an ``ImageResource``. The variant's total size is
    /// computed from these pieces during initialization.
    public struct ManifestContent {
        /// The manifest descriptor as listed in the image index.
        public let descriptor: Descriptor
        /// The platform manifest.
        public let manifest: ContainerizationOCI.Manifest
        /// The OCI image config for the platform.
        public let config: ContainerizationOCI.Image

        public init(descriptor: Descriptor, manifest: ContainerizationOCI.Manifest, config: ContainerizationOCI.Image) {
            self.descriptor = descriptor
            self.manifest = manifest
            self.config = config
        }
    }

    /// The image's description — its reference and index descriptor.
    public let config: ImageDescription

    /// The resolved index descriptor for the image.
    public let index: Descriptor

    /// The platform-specific variants contained in the image.
    public let variants: [Variant]

    /// The reference to show in human-facing listings, with default-registry
    /// information removed (e.g. `alpine` rather than `docker.io/library/alpine`).
    /// Computed by the caller, which has access to the system configuration.
    /// Defaults to the full ``name`` when not supplied.
    public let displayReference: String

    /// The creation date resolved from the OCI image config, if available.
    private let created: Date?

    // MARK: ManagedResource

    /// The unique identifier for this image. Identical to the image's index digest.
    public var id: String { config.digest }

    /// The user-facing reference (`name:tag`) for this image.
    public var name: String { config.reference }

    /// The time at which the image was created, resolved from the OCI image
    /// config. Falls back to the Unix epoch when no creation date is recorded.
    public var creationDate: Date { created ?? Date(timeIntervalSince1970: 0) }

    /// Key-value labels for this image, derived from the index descriptor's
    /// annotations. Returns an empty label set if the annotations fail
    /// ``ResourceLabels`` validation.
    public var labels: ResourceLabels {
        (try? ResourceLabels(config.descriptor.annotations ?? [:])) ?? ResourceLabels()
    }

    // MARK: Initialization

    /// Creates an image resource.
    ///
    /// - Parameters:
    ///   - config: The image's description (reference and index descriptor).
    ///   - index: The resolved index descriptor.
    ///   - variants: The per-platform variants contained in the image.
    ///   - created: The creation date resolved from the OCI image config, if any.
    ///   - displayReference: The denormalized reference for human-facing
    ///     listings. Defaults to the full reference when `nil`.
    public init(config: ImageDescription, index: Descriptor, variants: [Variant], created: Date? = nil, displayReference: String? = nil) {
        self.config = config
        self.index = index
        self.variants = variants
        self.created = created
        self.displayReference = displayReference ?? config.reference
    }
}

extension ImageResource {
    /// Creates an image resource from already-resolved index and manifest
    /// content.
    ///
    /// This initializer performs the variant resolution: it computes each
    /// platform variant's total size (manifest descriptor + config + layers)
    /// and derives the image's creation date from the earliest variant's OCI
    /// config `created` timestamp.
    ///
    /// - Parameters:
    ///   - config: The image's description (reference and index descriptor).
    ///   - index: The resolved index descriptor.
    ///   - manifests: The already-resolved per-platform manifest content.
    ///   - displayReference: The denormalized reference for human-facing
    ///     listings. Defaults to the full reference when `nil`.
    public init(config: ImageDescription, index: Descriptor, manifests: [ManifestContent], displayReference: String? = nil) {
        var variants: [Variant] = []
        var created: Date?
        for content in manifests {
            guard let platform = content.descriptor.platform else {
                continue
            }
            let size =
                content.descriptor.size + content.manifest.config.size
                + content.manifest.layers.reduce(0) { $0 + $1.size }
            variants.append(Variant(platform: platform, digest: content.descriptor.digest, size: size, config: content.config))
            // Use the earliest variant's creation timestamp as the image's date.
            if let createdString = content.config.created, let date = Self.parseCreated(createdString) {
                created = created.map { min($0, date) } ?? date
            }
        }
        self.init(config: config, index: index, variants: variants, created: created, displayReference: displayReference)
    }

    private static func parseCreated(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

extension ImageResource {
    /// Returns `true` if `name` is a syntactically valid image reference.
    public static func nameValid(_ name: String) -> Bool {
        (try? Reference.parse(name)) != nil
    }
}

// MARK: - Codable

extension ImageResource {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case creationDate
        case labels
        case configuration
        case index
        case variants
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(creationDate, forKey: .creationDate)
        try container.encode(labels, forKey: .labels)
        try container.encode(config, forKey: .configuration)
        try container.encode(index, forKey: .index)
        try container.encode(variants, forKey: .variants)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.config = try container.decode(ImageDescription.self, forKey: .configuration)
        self.index = try container.decode(Descriptor.self, forKey: .index)
        self.variants = try container.decode([Variant].self, forKey: .variants)
        self.created = try container.decodeIfPresent(Date.self, forKey: .creationDate)
        // `displayReference` is a display-only value and is not serialized.
        self.displayReference = self.config.reference
    }
}
