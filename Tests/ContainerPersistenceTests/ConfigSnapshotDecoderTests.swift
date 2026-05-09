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

struct ConfigSnapshotDecoderTests {

    struct FlatConfig: Decodable, Equatable {
        var host: String
        var port: Int
        var debug: Bool
        var rate: Double
    }

    @Test func decodeFlatStruct() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "host": ConfigValue(.string("localhost"), isSecret: false),
                "port": ConfigValue(.int(8080), isSecret: false),
                "debug": ConfigValue(.bool(true), isSecret: false),
                "rate": ConfigValue(.double(0.5), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(FlatConfig.self, from: snapshot)
        #expect(config.host == "localhost")
        #expect(config.port == 8080)
        #expect(config.debug == true)
        #expect(config.rate == 0.5)
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
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "database.host": ConfigValue(.string("db.example.com"), isSecret: false),
                "database.port": ConfigValue(.int(5432), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(NestedConfig.self, from: snapshot)
        #expect(config.database.host == "db.example.com")
        #expect(config.database.port == 5432)
    }

    // MARK: - Optional properties

    struct OptionalConfig: Decodable, Equatable {
        var name: String
        var nickname: String?
    }

    @Test func decodeOptionalPresent() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "name": ConfigValue(.string("Alice"), isSecret: false),
                "nickname": ConfigValue(.string("Ali"), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(OptionalConfig.self, from: snapshot)
        #expect(config.name == "Alice")
        #expect(config.nickname == "Ali")
    }

    @Test func decodeOptionalMissing() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "name": ConfigValue(.string("Alice"), isSecret: false)
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(OptionalConfig.self, from: snapshot)
        #expect(config.name == "Alice")
        #expect(config.nickname == nil)
    }

    // MARK: - Arrays

    struct ArrayConfig: Decodable, Equatable {
        var tags: [String]
        var counts: [Int]
    }

    @Test func decodeArrays() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "tags": ConfigValue(.stringArray(["swift", "config"]), isSecret: false),
                "counts": ConfigValue(.intArray([1, 2, 3]), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(ArrayConfig.self, from: snapshot)
        #expect(config.tags == ["swift", "config"])
        #expect(config.counts == [1, 2, 3])
    }

    struct MoreArraysConfig: Decodable, Equatable {
        var rates: [Double]
        var flags: [Bool]
    }

    @Test func decodeDoubleAndBoolArrays() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "rates": ConfigValue(.doubleArray([1.5, 2.5, 3.5]), isSecret: false),
                "flags": ConfigValue(.boolArray([true, false, true]), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(MoreArraysConfig.self, from: snapshot)
        #expect(config.rates == [1.5, 2.5, 3.5])
        #expect(config.flags == [true, false, true])
    }

    // MARK: - Error cases

    struct RequiredConfig: Decodable {
        var name: String
        var age: Int
    }

    @Test func decodeMissingRequiredKeyThrows() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "name": ConfigValue(.string("Alice"), isSecret: false)
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(RequiredConfig.self, from: snapshot)
        }
    }

    struct IntConfig: Decodable {
        var count: Int
    }

    @Test func decodeTypeMismatchThrows() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "count": ConfigValue(.string("not-a-number"), isSecret: false)
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(IntConfig.self, from: snapshot)
        }
    }

    struct ArrayOfStructsConfig: Decodable {
        var items: [DatabaseConfig]
    }

    @Test func decodeArrayOfStructsThrows() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [:]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(ArrayOfStructsConfig.self, from: snapshot)
        }
    }

    // MARK: - Scoped snapshot

    @Test func decodeScopedSnapshot() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "app.host": ConfigValue(.string("localhost"), isSecret: false),
                "app.port": ConfigValue(.int(3000), isSecret: false),
                "app.debug": ConfigValue(.bool(false), isSecret: false),
                "app.rate": ConfigValue(.double(1.0), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot().scoped(to: "app")
        let config = try ConfigSnapshotDecoder().decode(FlatConfig.self, from: snapshot)
        #expect(config.host == "localhost")
        #expect(config.port == 3000)
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
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "server-host": ConfigValue(.string("example.com"), isSecret: false),
                "server-port": ConfigValue(.int(443), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(CustomKeysConfig.self, from: snapshot)
        #expect(config.serverHost == "example.com")
        #expect(config.serverPort == 443)
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
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "env": ConfigValue(.string("production"), isSecret: false)
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(EnumConfig.self, from: snapshot)
        #expect(config.env == .production)
    }

    // MARK: - URL string fallback

    struct URLConfig: Decodable {
        var endpoint: URL
    }

    @Test func decodeURL() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "endpoint": ConfigValue(.string("https://example.com/api"), isSecret: false)
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(URLConfig.self, from: snapshot)
        #expect(config.endpoint == URL(string: "https://example.com/api")!)
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

    @Test func customStrategyOverridesURL() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "endpoint": ConfigValue(.string("/api/v1"), isSecret: false)
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let decoder = ConfigSnapshotDecoder(
            decodingStrategies: [PrefixURLStrategy(base: "https://example.com")]
        )
        let config = try decoder.decode(URLConfig.self, from: snapshot)
        #expect(config.endpoint == URL(string: "https://example.com/api/v1")!)
    }

    // MARK: - Narrow integer types

    struct NarrowIntConfig: Decodable, Equatable {
        var small: Int16
        var unsigned: UInt8
    }

    @Test func decodeNarrowIntegers() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "small": ConfigValue(.int(42), isSecret: false),
                "unsigned": ConfigValue(.int(200), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(NarrowIntConfig.self, from: snapshot)
        #expect(config.small == 42)
        #expect(config.unsigned == 200)
    }

    @Test func decodeIntegerOverflowThrows() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "small": ConfigValue(.int(42), isSecret: false),
                "unsigned": ConfigValue(.int(300), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        #expect(throws: DecodingError.self) {
            try ConfigSnapshotDecoder().decode(NarrowIntConfig.self, from: snapshot)
        }
    }

    @Test func removeStrategyRevertsToDecodable() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "endpoint": ConfigValue(.string("https://example.com/api"), isSecret: false)
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let decoder = ConfigSnapshotDecoder(decodingStrategies: [])
        // Without the URL strategy, URL.init(from:) is used. URL's default
        // Decodable expects a keyed container with "relative" and optional
        // "base" keys, so decoding a plain string should fail.
        #expect(throws: DecodingError.self) {
            try decoder.decode(URLConfig.self, from: snapshot)
        }
    }

    struct Seconds: Decodable {
        var value: Int
    }

    struct SecondsStrategy: ConfigDecodingStrategy {
        func decode(from decoder: Decoder) throws -> Seconds {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(Int.self)
            return Seconds(value: raw)
        }
    }

    struct TimerConfig: Decodable {
        var timeout: Seconds
    }

    @Test func customStrategyForUserType() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "timeout": ConfigValue(.int(30), isSecret: false)
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let decoder = ConfigSnapshotDecoder(decodingStrategies: [
            URLConfigDecodingStrategy(),
            SecondsStrategy(),
        ])
        let config = try decoder.decode(TimerConfig.self, from: snapshot)
        #expect(config.timeout.value == 30)
    }

    struct NestedURLConfig: Decodable {
        var service: ServiceConfig
    }

    struct ServiceConfig: Decodable {
        var endpoint: URL
        var name: String
    }

    @Test func strategyWorksInNestedStruct() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "service.endpoint": ConfigValue(.string("https://nested.example.com"), isSecret: false),
                "service.name": ConfigValue(.string("api"), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(NestedURLConfig.self, from: snapshot)
        #expect(config.service.endpoint == URL(string: "https://nested.example.com")!)
        #expect(config.service.name == "api")
    }

    // MARK: - Float decoding

    struct FloatConfig: Decodable, Equatable {
        var temperature: Float
        var ratio: Float
    }

    @Test func decodeFloat() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "temperature": ConfigValue(.double(98.6), isSecret: false),
                "ratio": ConfigValue(.double(0.333), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(FloatConfig.self, from: snapshot)
        #expect(config.temperature == Float(98.6))
        #expect(config.ratio == Float(0.333))
    }

    // MARK: - Deeply nested structs (3+ levels)

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
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "cluster.primary.host": ConfigValue(.string("node1.example.com"), isSecret: false),
                "cluster.primary.port": ConfigValue(.int(9090), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(AppConfig.self, from: snapshot)
        #expect(config.cluster.primary.host == "node1.example.com")
        #expect(config.cluster.primary.port == 9090)
    }

    // MARK: - Optional non-string types

    struct OptionalIntConfig: Decodable, Equatable {
        var name: String
        var retries: Int?
        var verbose: Bool?
        var rate: Double?
    }

    @Test func decodeOptionalNonStringPresent() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "name": ConfigValue(.string("test"), isSecret: false),
                "retries": ConfigValue(.int(3), isSecret: false),
                "verbose": ConfigValue(.bool(true), isSecret: false),
                "rate": ConfigValue(.double(0.75), isSecret: false),
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(OptionalIntConfig.self, from: snapshot)
        #expect(config.name == "test")
        #expect(config.retries == 3)
        #expect(config.verbose == true)
        #expect(config.rate == 0.75)
    }

    @Test func decodeOptionalNonStringMissing() throws {
        let provider = InMemoryProvider(
            name: "test",
            values: [
                "name": ConfigValue(.string("test"), isSecret: false)
            ]
        )
        let reader = ConfigReader(provider: provider)
        let snapshot = reader.snapshot()
        let config = try ConfigSnapshotDecoder().decode(OptionalIntConfig.self, from: snapshot)
        #expect(config.name == "test")
        #expect(config.retries == nil)
        #expect(config.verbose == nil)
        #expect(config.rate == nil)
    }
}
