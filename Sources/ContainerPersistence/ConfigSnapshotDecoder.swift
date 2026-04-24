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

import Configuration

/// A decoder that decodes `Decodable` types from a ``ConfigSnapshotReader``.
///
/// `ConfigSnapshotDecoder` bridges Swift's `Decodable` protocol with the configuration
/// provider system, allowing you to decode structured configuration into typed
/// Swift values.
///
/// ```swift
/// struct AppConfig: Decodable {
///     var host: String
///     var port: Int
///     var database: DatabaseConfig
/// }
///
/// struct DatabaseConfig: Decodable {
///     var connectionString: String
///     var maxConnections: Int
/// }
///
/// let reader = ConfigReader(providers: [envProvider, jsonProvider])
/// let snapshot = reader.snapshot()
/// let config = try ConfigSnapshotDecoder().decode(AppConfig.self, from: snapshot)
/// ```
///
/// Nested structs map to dot-separated key paths. In the example above,
/// `database.connectionString` and `database.maxConnections` are looked up
/// from the snapshot.
public struct ConfigSnapshotDecoder: Sendable {

    public var userInfo: [CodingUserInfoKey: any Sendable]

    public init() {
        self.userInfo = [:]
    }

    public func decode<T: Decodable>(
        _ type: T.Type,
        from snapshot: ConfigSnapshotReader
    ) throws -> T {
        let decoder = ConfigSnapshotDecoderImpl(
            snapshot: snapshot,
            codingPath: [],
            userInfo: userInfo.mapValues { $0 as Any }
        )
        return try T(from: decoder)
    }
}

struct ConfigSnapshotDecoderImpl: Decoder {
    let snapshot: ConfigSnapshotReader
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    func container<Key: CodingKey>(
        keyedBy type: Key.Type
    ) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(
            KeyedContainer<Key>(
                snapshot: snapshot,
                codingPath: codingPath,
                userInfo: userInfo
            )
        )
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        UnkeyedContainer(
            snapshot: snapshot,
            codingPath: codingPath,
            userInfo: userInfo
        )
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleValueContainer(
            snapshot: snapshot,
            codingPath: codingPath,
            userInfo: userInfo
        )
    }
}
