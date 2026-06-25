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

/// A type that provides custom decoding logic for a specific `Decodable` type
/// when using `ConfigSnapshotDecoder`. This enables modification of `Decodable` behavior
/// for types that already conform to `Decodable`, such as `URL` and `Measurement`.
public protocol ConfigDecodingStrategy: Sendable {
    associatedtype Value: Decodable
    func decode(from decoder: Decoder) throws -> Value
}

/// A type that provides custom encoding logic for a specific `Encodable` type.
/// This enables modification of `Encodable` behavior for types that already conform
// to `Encodable`, such as `URL` and `Measurement`.
public protocol ConfigEncodingStrategy: Sendable {
    associatedtype Value: Encodable
    func encode(_ value: Value, to encoder: Encoder) throws
}

/// A type that provides both custom encoding and decoding for the same type. Similar to `Codable`
public typealias ConfigCodingStrategy = ConfigDecodingStrategy & ConfigEncodingStrategy

/// Decodes a `URL` from a string value. e.g. "https://www.apple.com"
public struct URLConfigDecodingStrategy: ConfigDecodingStrategy {
    public init() {}

    public func decode(from decoder: Decoder) throws -> URL {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let url = URL(string: string) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid URL string: \"\(string)\"."
                )
            )
        }
        return url
    }
}

// A type erased version of `ConfigDecodingStrategy`
struct AnyConfigDecodingStrategy: Sendable {
    let valueTypeID: ObjectIdentifier
    private let decode: @Sendable (Decoder) throws -> Any

    init<S: ConfigDecodingStrategy>(_ strategy: S) {
        self.valueTypeID = ObjectIdentifier(S.Value.self)
        self.decode = { decoder in try strategy.decode(from: decoder) as Any }
    }

    func decode(from decoder: Decoder) throws -> Any {
        try decode(decoder)
    }
}
