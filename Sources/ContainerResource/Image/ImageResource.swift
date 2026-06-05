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

    public struct ImageConfiguration: Sendable, Codable {
        public let creationDate: Date
        public var name: String
        public var descriptor: Descriptor

        public init(description: ImageDescription, creationDate: Date) {
            self.creationDate = creationDate
            self.name = description.reference
            self.descriptor = description.descriptor
        }
    }

    /// The image's description — its reference and index descriptor.
    public let configuration: ImageConfiguration

    /// The platform-specific variants contained in the image.
    public let variants: [Variant]

    /// The reference to show in human-facing listings, with default-registry
    /// information removed (e.g. `alpine` rather than `docker.io/library/alpine`).
    /// Computed by the caller, which has access to the system configuration.
    /// Defaults to the full ``name`` when not supplied.
    public let displayReference: String

    // MARK: ManagedResource

    /// The unique identifier for this image. Identical to the image's index digest.
    public var id: String { configuration.descriptor.digest }

    /// The user-facing reference (`name:tag`) for this image.
    public var name: String { configuration.name }

    /// The time at which the image was created, resolved from the OCI image
    /// config. Falls back to the Unix epoch when no creation date is recorded.
    public var creationDate: Date { configuration.creationDate }

    /// Key-value labels for this image, derived from the index descriptor's
    /// annotations. Returns an empty label set if the annotations fail
    /// ``ResourceLabels`` validation.
    public var labels: ResourceLabels {
        (try? ResourceLabels(configuration.descriptor.annotations ?? [:])) ?? ResourceLabels()
    }

    // MARK: Initialization
    public init(configuration: ImageConfiguration, variants: [Variant], displayReference: String? = nil) {
        self.configuration = configuration
        self.variants = variants
        self.displayReference = displayReference ?? configuration.name
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
        case configuration
        case variants
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(variants, forKey: .variants)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.configuration = try container.decode(ImageConfiguration.self, forKey: .configuration)
        self.variants = try container.decode([Variant].self, forKey: .variants)
        // `displayReference` is a display-only value and is not serialized.
        self.displayReference = self.configuration.name
    }
}
