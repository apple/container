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

/// A volume resource, representing a configured volume.
public struct VolumeResource: ManagedResource {
    /// The volume's configuration — its persistent, intrinsic properties.
    public let configuration: VolumeConfiguration

    // MARK: ManagedResource

    /// The unique identifier for this volume. Identical to ``VolumeConfiguration/name``.
    public var id: String { configuration.name }

    /// The user-assigned name for this volume. For volumes, name and ID are the same.
    public var name: String { configuration.name }

    /// The time at which this volume was created.
    public var creationDate: Date { configuration.creationDate }

    /// Key-value labels for this volume. If the underlying
    /// ``VolumeConfiguration/labels`` dictionary contains values that fail
    /// ``ResourceLabels`` validation, this returns an empty label set.
    public var labels: ResourceLabels {
        (try? ResourceLabels(configuration.labels)) ?? ResourceLabels()
    }

    /// Whether this is an anonymous volume (detected via the configuration's labels).
    public var isAnonymous: Bool { configuration.isAnonymous }

    // MARK: Initialization

    /// Creates a volume resource.
    ///
    /// - Parameters:
    ///   - configuration: The volume's intrinsic configuration.
    public init(configuration: VolumeConfiguration) {
        self.configuration = configuration
    }
}

extension VolumeResource {
    public static let volumeNamePattern = "^[A-Za-z0-9][A-Za-z0-9_.-]*$"

    /// Returns `true` if `name` is a syntactically valid volume identifier.
    public static func nameValid(_ name: String) -> Bool {
        guard name.count <= 255 else { return false }

        do {
            let regex = try Regex(volumeNamePattern)
            return (try? regex.wholeMatch(in: name)) != nil
        } catch {
            return false
        }
    }
}

// MARK: - Codable

extension VolumeResource {
    enum CodingKeys: String, CodingKey {
        case id
        case configuration
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(configuration, forKey: .configuration)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.configuration = try container.decode(VolumeConfiguration.self, forKey: .configuration)
    }
}
