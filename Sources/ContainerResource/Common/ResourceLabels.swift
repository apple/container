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

import Collections

/// Metadata for a managed resource.
public struct ResourceLabels: Sendable, Equatable {
    public static let keyLengthMax = 128

    public static let labelLengthMax = 4096

    public let dictionary: [String: String]

    public struct LabelError: AppError {
        public var code: AppErrorCode

        public var metadata: OrderedDictionary<String, String>

        public var underlyingError: (any Error)? { nil }
    }

    public init() {
        dictionary = [:]
    }

    public init(_ labels: [String: String]) throws {
        for (key, value) in labels {
            try Self.validateLabel(key: key, value: value)
        }
        self.dictionary = labels
    }

    public static func validateLabelKey(_ key: String) throws {
        guard key.count <= Self.keyLengthMax else {
            throw LabelError(code: .invalidLabelKeyLength, metadata: ["key": key, "maxLength": "\(Self.keyLengthMax)"])
        }
        let dockerPattern = #/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*$/#
        let ociPattern = #/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*(?:/(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*))*$/#
        let dockerMatch = !key.ranges(of: dockerPattern).isEmpty
        let ociMatch = !key.ranges(of: ociPattern).isEmpty
        guard dockerMatch || ociMatch else {
            throw LabelError(code: .invalidLabelKeyContent, metadata: ["key": key])
        }
    }

    public static func validateLabel(key: String, value: String) throws {
        try validateLabelKey(key)
        let fullLabel = "\(key)=\(value)"
        guard fullLabel.count <= labelLengthMax else {
            throw LabelError(code: .invalidLabelLength, metadata: ["label": fullLabel, "maxLength": "\(Self.labelLengthMax)"])
        }
    }
}

extension ResourceLabels: Codable {
    public func encode(to encoder: Encoder) throws {
        try dictionary.encode(to: encoder)
    }

    public init(from decoder: Decoder) throws {
        let dict = try [String: String](from: decoder)
        try self.init(dict)
    }
}

extension ResourceLabels: Collection {
    public typealias Index = Dictionary<String, String>.Index
    public typealias Element = Dictionary<String, String>.Element

    public var startIndex: Index { dictionary.startIndex }
    public var endIndex: Index { dictionary.endIndex }

    public subscript(position: Index) -> Element { dictionary[position] }
    public func index(after i: Index) -> Index { dictionary.index(after: i) }

    // Direct key access
    public subscript(key: String) -> String? {
        get { dictionary[key] }
    }
}

extension AppErrorCode {
    public static let invalidLabelKeyContent = AppErrorCode(rawValue: "invalid_label_key_content")
    public static let invalidLabelKeyLength = AppErrorCode(rawValue: "invalid_label_key_length")
    public static let invalidLabelLength = AppErrorCode(rawValue: "invalid_label_length")
}

/// System-defined keys for resource labels.
public struct ResourceLabelKeys {
    /// Indicates a owner of a resource managed by a plugin.
    public static let plugin = "com.apple.container.plugin"

    /// Indicates a resource with a reserved or dedicated purpose.
    public static let role = "com.apple.container.resource.role"
}

/// System-defined values for resource the resource role label.
public struct ResourceRoleValues {
    /// Indicates a container that can build images.
    public static let builder = "builder"

    /// Indicates a system-created resource that cannot be deleted by the user.
    public static let builtin = "builtin"
}
