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
import ContainerPersistence
import Foundation
import Testing

private func makeSnapshot(_ values: [AbsoluteConfigKey: ConfigValue] = [:]) -> ConfigSnapshotReader {
    ConfigReader(provider: InMemoryProvider(name: "test", values: values)).snapshot()
}

struct ConfigSnapshotDecoderTests {

    struct FlatConfig: Decodable, Equatable {
        var host: String
        var port: Int
        var debug: Bool
        var rate: Double
    }

    @Test func decodeFlatStruct() throws {
        let snapshot = makeSnapshot([
            "host": "localhost",
            "port": 8080,
            "debug": true,
            "rate": 0.5,
        ])
        let config = try ConfigSnapshotDecoder().decode(FlatConfig.self, from: snapshot)
        #expect(config == FlatConfig(host: "localhost", port: 8080, debug: true, rate: 0.5))
    }

    // MARK: - Nested structs

    struct NestedConfig: Decodable, Equatable {
        var database: DatabaseConfig
    }

    struct DatabaseConfig: Decodable, Equatable {
        var host: String
        var port: Int
    }

    @Test func decodeNestedStruct() throws {
        let snapshot = makeSnapshot([
            "database.host": "db.example.com",
            "database.port": 5432,
        ])
        let config = try ConfigSnapshotDecoder().decode(NestedConfig.self, from: snapshot)
        #expect(config == NestedConfig(database: DatabaseConfig(host: "db.example.com", port: 5432)))
    }

    struct AppConfig: Decodable, Equatable {
        var cluster: ClusterConfig
    }

    struct ClusterConfig: Decodable, Equatable {
        var primary: NodeConfig
    }

    struct NodeConfig: Decodable, Equatable {
        var host: String
        var port: Int
    }

    @Test func decodeDeeplyNestedStruct() throws {
        let snapshot = makeSnapshot([
            "cluster.primary.host": "node1.example.com",
            "cluster.primary.port": 9090,
        ])
        let config = try ConfigSnapshotDecoder().decode(AppConfig.self, from: snapshot)
        #expect(
            config
                == AppConfig(cluster: ClusterConfig(primary: NodeConfig(host: "node1.example.com", port: 9090)))
        )
    }

    // MARK: - Optional properties

    struct OptionalPrimitivesConfig: Decodable, Equatable {
        var name: String?
        var count: Int?
        var rate: Double?
        var ratio: Float?
        var flag: Bool?
    }

    @Test func decodeOptionalsPresent() throws {
        let snapshot = makeSnapshot([
            "name": "test",
            "count": 3,
            "rate": 0.75,
            "ratio": 0.5,
            "flag": true,
        ])
        let config = try ConfigSnapshotDecoder().decode(OptionalPrimitivesConfig.self, from: snapshot)
        #expect(
            config == OptionalPrimitivesConfig(name: "test", count: 3, rate: 0.75, ratio: 0.5, flag: true)
        )
    }

    @Test func decodeOptionalsAbsent() throws {
        let snapshot = makeSnapshot()
        let config = try ConfigSnapshotDecoder().decode(OptionalPrimitivesConfig.self, from: snapshot)
        #expect(config == OptionalPrimitivesConfig())
    }

    // Each test below provides one wrong-typed value so a mistyped user config
    // surfaces as DecodingError rather than silently falling back to nil.
    // See ConfigSnapshotDecoderContainers `decodeIfPresent` overrides.

    @Test func decodeOptionalIntWithStringThrows() {
        let snapshot = makeSnapshot(["count": "8"])
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(OptionalPrimitivesConfig.self, from: snapshot)
        }
    }

    @Test func decodeOptionalBoolWithIntThrows() {
        let snapshot = makeSnapshot(["flag": 1])
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(OptionalPrimitivesConfig.self, from: snapshot)
        }
    }

    @Test func decodeOptionalStringWithBoolThrows() {
        let snapshot = makeSnapshot(["name": true])
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(OptionalPrimitivesConfig.self, from: snapshot)
        }
    }

    @Test func decodeOptionalDoubleWithStringThrows() {
        let snapshot = makeSnapshot(["rate": "0.5"])
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(OptionalPrimitivesConfig.self, from: snapshot)
        }
    }

    @Test func decodeOptionalFloatWithStringThrows() {
        let snapshot = makeSnapshot(["ratio": "0.5"])
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(OptionalPrimitivesConfig.self, from: snapshot)
        }
    }

    // Regression: see KeyedContainer.decodeNil(forKey:) docs. The flat snapshot
    // stores `build.cpus` but no entry for `build` itself; an earlier version of
    // decodeNil returned true for `build`, causing decodeIfPresent to return nil
    // even though `build.*` keys existed.

    struct BuildConfig: Decodable, Equatable {
        var cpus: Int
    }

    struct ParentConfig: Decodable, Equatable {
        var build: BuildConfig?
    }

    @Test func decodeIfPresentNestedStruct() throws {
        let snapshot = makeSnapshot(["build.cpus": 4])
        let config = try ConfigSnapshotDecoder().decode(ParentConfig.self, from: snapshot)
        #expect(config == ParentConfig(build: BuildConfig(cpus: 4)))
    }

    // MARK: - Arrays

    struct ArrayConfig: Decodable, Equatable {
        var tags: [String]
        var counts: [Int]
        var rates: [Double]
        var flags: [Bool]
    }

    @Test func decodeArrays() throws {
        let snapshot = makeSnapshot([
            "tags": ConfigValue(.stringArray(["swift", "config"]), isSecret: false),
            "counts": ConfigValue(.intArray([1, 2, 3]), isSecret: false),
            "rates": ConfigValue(.doubleArray([1.5, 2.5, 3.5]), isSecret: false),
            "flags": ConfigValue(.boolArray([true, false, true]), isSecret: false),
        ])
        let config = try ConfigSnapshotDecoder().decode(ArrayConfig.self, from: snapshot)
        #expect(
            config
                == ArrayConfig(
                    tags: ["swift", "config"],
                    counts: [1, 2, 3],
                    rates: [1.5, 2.5, 3.5],
                    flags: [true, false, true]
                )
        )
    }

    struct ArrayOfStructsConfig: Decodable {
        var items: [DatabaseConfig]
    }

    @Test func decodeArrayOfStructsThrows() {
        let snapshot = makeSnapshot()
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(ArrayOfStructsConfig.self, from: snapshot)
        }
    }

    // MARK: - Custom CodingKeys

    struct CustomKeysConfig: Decodable, Equatable {
        var serverHost: String
        var serverPort: Int

        enum CodingKeys: String, CodingKey {
            case serverHost = "server-host"
            case serverPort = "server-port"
        }
    }

    @Test func decodeCustomCodingKeys() throws {
        let snapshot = makeSnapshot([
            "server-host": "example.com",
            "server-port": 443,
        ])
        let config = try ConfigSnapshotDecoder().decode(CustomKeysConfig.self, from: snapshot)
        #expect(config == CustomKeysConfig(serverHost: "example.com", serverPort: 443))
    }

    // MARK: - Enum with raw value

    enum Environment: String, Decodable {
        case development
        case staging
        case production
    }

    struct EnumConfig: Decodable, Equatable {
        var env: Environment
    }

    @Test func decodeEnum() throws {
        let snapshot = makeSnapshot(["env": "production"])
        let config = try ConfigSnapshotDecoder().decode(EnumConfig.self, from: snapshot)
        #expect(config == EnumConfig(env: .production))
    }

    // MARK: - Narrow integer types

    struct NarrowIntConfig: Decodable, Equatable {
        var small: Int16
        var unsigned: UInt8
    }

    @Test func decodeNarrowIntegers() throws {
        let snapshot = makeSnapshot([
            "small": 42,
            "unsigned": 200,
        ])
        let config = try ConfigSnapshotDecoder().decode(NarrowIntConfig.self, from: snapshot)
        #expect(config == NarrowIntConfig(small: 42, unsigned: 200))
    }

    @Test func decodeIntegerOverflowThrows() {
        let snapshot = makeSnapshot([
            "small": 42,
            "unsigned": 300,
        ])
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(NarrowIntConfig.self, from: snapshot)
        }
    }

    // MARK: - Float decoding

    struct FloatConfig: Decodable, Equatable {
        var temperature: Float
        var ratio: Float
    }

    @Test func decodeFloat() throws {
        let snapshot = makeSnapshot([
            "temperature": 98.6,
            "ratio": 0.333,
        ])
        let config = try ConfigSnapshotDecoder().decode(FloatConfig.self, from: snapshot)
        #expect(config == FloatConfig(temperature: Float(98.6), ratio: Float(0.333)))
    }

    // MARK: - Scoped snapshot

    @Test func decodeScopedSnapshot() throws {
        let snapshot = makeSnapshot([
            "app.host": "localhost",
            "app.port": 3000,
            "app.debug": false,
            "app.rate": 1.0,
        ]).scoped(to: "app")
        let config = try ConfigSnapshotDecoder().decode(FlatConfig.self, from: snapshot)
        #expect(config == FlatConfig(host: "localhost", port: 3000, debug: false, rate: 1.0))
    }

    @Test func decodeTopLevelPrimitive() throws {
        let snapshot = makeSnapshot(["value": 42]).scoped(to: "value")
        let value = try ConfigSnapshotDecoder().decode(Int.self, from: snapshot)
        #expect(value == 42)
    }

    // MARK: - Error cases

    struct RequiredConfig: Decodable {
        var name: String
        var age: Int
    }

    @Test func decodeMissingRequiredKeyThrows() {
        let snapshot = makeSnapshot(["name": "Alice"])
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(RequiredConfig.self, from: snapshot)
        }
    }

    struct IntConfig: Decodable {
        var count: Int
    }

    @Test func decodeTypeMismatchThrows() {
        let snapshot = makeSnapshot(["count": "not-a-number"])
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(IntConfig.self, from: snapshot)
        }
    }

    // Regression: see UnsupportedDictionaryDecoding marker docs. Dictionaries
    // would otherwise silently decode to [:] because the snapshot has no
    // key-enumeration API.

    struct DictConfig: Decodable {
        var tags: [String: String]
    }

    @Test func decodeDictionaryPropertyThrows() {
        let snapshot = makeSnapshot(["tags.env": "prod"])
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(DictConfig.self, from: snapshot)
        }
    }

    @Test func decodeTopLevelDictionaryThrows() {
        let snapshot = makeSnapshot()
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode([String: Int].self, from: snapshot)
        }
    }

    // MARK: - URL string fallback

    struct URLConfig: Decodable, Equatable {
        var endpoint: URL
    }

    @Test func decodeURL() throws {
        let snapshot = makeSnapshot(["endpoint": "https://example.com/api"])
        let config = try ConfigSnapshotDecoder().decode(URLConfig.self, from: snapshot)
        #expect(config == URLConfig(endpoint: URL(string: "https://example.com/api")!))
    }

    // MARK: - Custom decoding strategies

    struct PrefixURLStrategy: ConfigDecodingStrategy {
        let base: String

        func decode(from decoder: Decoder) throws -> URL {
            let container = try decoder.singleValueContainer()
            let path = try container.decode(String.self)
            guard let url = URL(string: base + path) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Invalid URL."
                    )
                )
            }
            return url
        }
    }

    @Test func decodeURLWithCustomStrategy() throws {
        let snapshot = makeSnapshot(["endpoint": "/api/v1"])
        let decoder = ConfigSnapshotDecoder(
            decodingStrategies: [PrefixURLStrategy(base: "https://example.com")]
        )
        let config = try decoder.decode(URLConfig.self, from: snapshot)
        #expect(config == URLConfig(endpoint: URL(string: "https://example.com/api/v1")!))
    }

    @Test func decodeURLWithoutStrategyThrows() {
        let snapshot = makeSnapshot(["endpoint": "https://example.com/api"])
        let decoder = ConfigSnapshotDecoder(decodingStrategies: [])
        #expect(throws: DecodingError.self) {
            try decoder.decode(URLConfig.self, from: snapshot)
        }
    }

    struct NestedURLConfig: Decodable, Equatable {
        var service: ServiceConfig
    }

    struct ServiceConfig: Decodable, Equatable {
        var endpoint: URL
        var name: String
    }

    @Test func decodeNestedStructWithURLStrategy() throws {
        let snapshot = makeSnapshot([
            "service.endpoint": "https://nested.example.com",
            "service.name": "api",
        ])
        let config = try ConfigSnapshotDecoder().decode(NestedURLConfig.self, from: snapshot)
        #expect(
            config
                == NestedURLConfig(
                    service: ServiceConfig(
                        endpoint: URL(string: "https://nested.example.com")!,
                        name: "api"
                    )
                )
        )
    }

    struct OptionalURLConfig: Decodable, Equatable {
        var endpoint: URL?
    }

    @Test func decodeOptionalURLWithStrategy() throws {
        let snapshot = makeSnapshot(["endpoint": "https://example.com"])
        let config = try ConfigSnapshotDecoder().decode(OptionalURLConfig.self, from: snapshot)
        #expect(config == OptionalURLConfig(endpoint: URL(string: "https://example.com")!))
    }

    struct Seconds: Decodable, Equatable {
        var value: Int
    }

    struct SecondsStrategy: ConfigDecodingStrategy {
        func decode(from decoder: Decoder) throws -> Seconds {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(Int.self)
            return Seconds(value: raw)
        }
    }

    struct TimerConfig: Decodable, Equatable {
        var timeout: Seconds
    }

    @Test func decodeUserTypeWithCustomStrategy() throws {
        let snapshot = makeSnapshot(["timeout": 30])
        let decoder = ConfigSnapshotDecoder(decodingStrategies: [
            URLConfigDecodingStrategy(),
            SecondsStrategy(),
        ])
        let config = try decoder.decode(TimerConfig.self, from: snapshot)
        #expect(config == TimerConfig(timeout: Seconds(value: 30)))
    }
}
