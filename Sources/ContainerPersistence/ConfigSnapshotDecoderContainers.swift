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
import Foundation

// MARK: - Shared helpers

extension ConfigSnapshotReader {
    /// Returns true when the snapshot holds a primitive value at `key`, regardless of
    /// type. `ConfigSnapshotReader` stores typed values — each primitive accessor returns
    /// nil both when the key is absent and when the stored value is of a different type.
    /// Callers that need to distinguish "absent" from "present but wrong type" must check
    /// `hasValue` first, then the typed accessor.
    func hasValue(forKey key: ConfigKey) -> Bool {
        string(forKey: key) != nil
            || int(forKey: key) != nil
            || double(forKey: key) != nil
            || bool(forKey: key) != nil
    }
}

/// Marker used by `decode<T>` to reject `Dictionary`-valued properties. The snapshot
/// has no key-enumeration API, so a `Dictionary` would silently decode to `[:]` via
/// `allKeys == []`. We reject the attempt explicitly instead.
protocol UnsupportedDictionaryDecoding {}
extension Dictionary: UnsupportedDictionaryDecoding {}

struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let snapshot: ConfigSnapshotReader
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    let typeDecodingStrategies: [ObjectIdentifier: AnyConfigDecodingStrategy]

    // ConfigSnapshotReader has no "key exists" API, so allKeys cannot enumerate
    // available keys and contains always returns true. This works for structs with
    // known properties. Types that iterate allKeys for dynamic keys (e.g. dictionaries)
    // will see an empty collection.
    var allKeys: [Key] { [] }

    func contains(_ key: Key) -> Bool { true }

    // Always return false — the flat config snapshot stores nested struct keys as
    // dot-separated paths (e.g. "build.cpus") but has no entry for the parent key
    // itself (e.g. "build"). Returning true here would cause decodeIfPresent to skip
    // structs whose child keys DO exist. Instead, we always attempt to decode and
    // rely on decodeIfPresent overrides for primitive optionals.
    func decodeNil(forKey key: Key) throws -> Bool {
        false
    }

    // MARK: - Primitive decodeIfPresent overrides
    //
    // Each override distinguishes three cases:
    //   1. key absent          → return nil
    //   2. key present, right type → return the value
    //   3. key present, wrong type → throw DecodingError.typeMismatch
    //
    // The typed accessors on ConfigSnapshotReader collapse (1) and (3) into nil,
    // so we use `hasValue` to disambiguate. Without this, a user config mistake
    // like `cpus = "8"` would silently fall back to the property's default.

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        let ck = configKey(appending: key)
        guard snapshot.hasValue(forKey: ck) else { return nil }
        guard let value = snapshot.bool(forKey: ck) else {
            throw typeMismatch(Bool.self, at: ck, for: key)
        }
        return value
    }

    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        let ck = configKey(appending: key)
        guard snapshot.hasValue(forKey: ck) else { return nil }
        guard let value = snapshot.string(forKey: ck) else {
            throw typeMismatch(String.self, at: ck, for: key)
        }
        return value
    }

    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        let ck = configKey(appending: key)
        guard snapshot.hasValue(forKey: ck) else { return nil }
        guard let value = snapshot.int(forKey: ck) else {
            throw typeMismatch(Int.self, at: ck, for: key)
        }
        return value
    }

    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        let ck = configKey(appending: key)
        guard snapshot.hasValue(forKey: ck) else { return nil }
        guard let value = snapshot.double(forKey: ck) else {
            throw typeMismatch(Double.self, at: ck, for: key)
        }
        return value
    }

    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? {
        let ck = configKey(appending: key)
        guard snapshot.hasValue(forKey: ck) else { return nil }
        guard let value = snapshot.double(forKey: ck) else {
            throw typeMismatch(Float.self, at: ck, for: key)
        }
        return Float(value)
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        // For non-primitive Decodable types, always attempt decode.
        // If the nested struct's init(from:) uses decodeIfPresent for its own keys,
        // missing keys will resolve to defaults correctly.
        // Catch keyNotFound/valueNotFound at this level — they indicate the key is absent.
        do {
            return try decode(type, forKey: key)
        } catch DecodingError.keyNotFound(let k, _) where k.stringValue == key.stringValue {
            return nil
        } catch DecodingError.valueNotFound {
            return nil
        }
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try decodeValue(forKey: key) { try snapshot.requiredBool(forKey: $0) }
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try decodeValue(forKey: key) { try snapshot.requiredString(forKey: $0) }
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try decodeValue(forKey: key) { try snapshot.requiredDouble(forKey: $0) }
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        Float(try decodeValue(forKey: key) { try snapshot.requiredDouble(forKey: $0) })
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try decodeValue(forKey: key) { try snapshot.requiredInt(forKey: $0) }
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try integerValue(forKey: key)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try integerValue(forKey: key)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try integerValue(forKey: key)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try integerValue(forKey: key)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try integerValue(forKey: key)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try integerValue(forKey: key)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try integerValue(forKey: key)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try integerValue(forKey: key)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try integerValue(forKey: key)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        if type is any UnsupportedDictionaryDecoding.Type {
            throw DecodingError.typeMismatch(
                T.self,
                DecodingError.Context(
                    codingPath: codingPath + [key],
                    debugDescription:
                        "ConfigSnapshotDecoder does not support decoding dictionaries (got \(T.self)). Represent dynamic keys as nested structs with known property names."
                )
            )
        }
        let impl = ConfigSnapshotDecoderImpl(
            snapshot: snapshot,
            codingPath: codingPath + [key],
            userInfo: userInfo,
            typeDecodingStrategies: typeDecodingStrategies
        )
        if let strategy = typeDecodingStrategies[ObjectIdentifier(type)] {
            guard let typed = try strategy.decode(from: impl) as? T else {
                throw DecodingError.typeMismatch(
                    T.self,
                    DecodingError.Context(
                        codingPath: codingPath + [key],
                        debugDescription: "Strategy returned value of unexpected type for \(T.self)."
                    )
                )
            }
            return typed
        }
        return try T(from: impl)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        KeyedDecodingContainer(
            KeyedContainer<NestedKey>(
                snapshot: snapshot,
                codingPath: codingPath + [key],
                userInfo: userInfo,
                typeDecodingStrategies: typeDecodingStrategies
            )
        )
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        UnkeyedContainer(
            snapshot: snapshot,
            codingPath: codingPath + [key],
            userInfo: userInfo,
            typeDecodingStrategies: typeDecodingStrategies
        )
    }

    func superDecoder() throws -> any Decoder {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "ConfigSnapshotDecoder does not support superDecoder()."
            )
        )
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "ConfigSnapshotDecoder does not support superDecoder(forKey:)."
            )
        )
    }

    // MARK: - Private helpers

    private func configKey(appending key: Key) -> ConfigKey {
        ConfigKey(codingPath.map(\.stringValue) + [key.stringValue])
    }

    private func decodeValue<V>(forKey key: Key, _ body: (ConfigKey) throws -> V) throws -> V {
        let configKey = configKey(appending: key)
        do {
            return try body(configKey)
        } catch {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No value found for key \"\(configKey)\"."
                )
            )
        }
    }

    private func integerValue<T: FixedWidthInteger>(forKey key: Key) throws -> T {
        let intValue: Int = try decodeValue(forKey: key) { try snapshot.requiredInt(forKey: $0) }
        guard let converted = T(exactly: intValue) else {
            throw DecodingError.typeMismatch(
                T.self,
                DecodingError.Context(
                    codingPath: codingPath + [key],
                    debugDescription: "Value \(intValue) does not fit in \(T.self)."
                )
            )
        }
        return converted
    }

    private func typeMismatch<T>(_ type: T.Type, at configKey: ConfigKey, for key: Key) -> DecodingError {
        DecodingError.typeMismatch(
            T.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected \(T.self) at \"\(configKey)\" but found a value of a different type."
            )
        )
    }
}

struct SingleValueContainer: SingleValueDecodingContainer {
    let snapshot: ConfigSnapshotReader
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    let typeDecodingStrategies: [ObjectIdentifier: AnyConfigDecodingStrategy]

    // ConfigSnapshotReader stores typed values — string(forKey:) returns nil for
    // int/double/bool values. `hasValue` checks all primitive accessors.
    func decodeNil() -> Bool {
        !snapshot.hasValue(forKey: configKey())
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try decodeValue { try snapshot.requiredBool(forKey: $0) }
    }

    func decode(_ type: String.Type) throws -> String {
        try decodeValue { try snapshot.requiredString(forKey: $0) }
    }

    func decode(_ type: Double.Type) throws -> Double {
        try decodeValue { try snapshot.requiredDouble(forKey: $0) }
    }

    func decode(_ type: Float.Type) throws -> Float {
        Float(try decodeValue { try snapshot.requiredDouble(forKey: $0) })
    }

    func decode(_ type: Int.Type) throws -> Int {
        try decodeValue { try snapshot.requiredInt(forKey: $0) }
    }

    func decode(_ type: Int8.Type) throws -> Int8 { try integerValue() }
    func decode(_ type: Int16.Type) throws -> Int16 { try integerValue() }
    func decode(_ type: Int32.Type) throws -> Int32 { try integerValue() }
    func decode(_ type: Int64.Type) throws -> Int64 { try integerValue() }
    func decode(_ type: UInt.Type) throws -> UInt { try integerValue() }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try integerValue() }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try integerValue() }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try integerValue() }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try integerValue() }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type is any UnsupportedDictionaryDecoding.Type {
            throw DecodingError.typeMismatch(
                T.self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription:
                        "ConfigSnapshotDecoder does not support decoding dictionaries (got \(T.self)). Represent dynamic keys as nested structs with known property names."
                )
            )
        }
        let impl = ConfigSnapshotDecoderImpl(
            snapshot: snapshot,
            codingPath: codingPath,
            userInfo: userInfo,
            typeDecodingStrategies: typeDecodingStrategies
        )
        if let strategy = typeDecodingStrategies[ObjectIdentifier(type)] {
            guard let typed = try strategy.decode(from: impl) as? T else {
                throw DecodingError.typeMismatch(
                    T.self,
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Strategy returned value of unexpected type for \(T.self)."
                    )
                )
            }
            return typed
        }
        return try T(from: impl)
    }

    // MARK: - Private helpers

    private func configKey() -> ConfigKey {
        ConfigKey(codingPath.map(\.stringValue))
    }

    private func decodeValue<V>(_ body: (ConfigKey) throws -> V) throws -> V {
        let configKey = configKey()
        do {
            return try body(configKey)
        } catch {
            throw DecodingError.valueNotFound(
                V.self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No value found for key \"\(configKey)\"."
                )
            )
        }
    }

    private func integerValue<T: FixedWidthInteger>() throws -> T {
        let intValue: Int = try decodeValue { try snapshot.requiredInt(forKey: $0) }
        guard let converted = T(exactly: intValue) else {
            throw DecodingError.typeMismatch(
                T.self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(intValue) does not fit in \(T.self)."
                )
            )
        }
        return converted
    }
}

struct UnkeyedContainer: UnkeyedDecodingContainer {
    let snapshot: ConfigSnapshotReader
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    let typeDecodingStrategies: [ObjectIdentifier: AnyConfigDecodingStrategy]

    private enum ArrayValue {
        case strings([String])
        case ints([Int])
        case doubles([Double])
        case bools([Bool])
        case unsupported
    }

    private var resolved: ArrayValue = .unsupported
    private(set) var currentIndex: Int = 0

    var count: Int? {
        switch resolved {
        case .strings(let a): a.count
        case .ints(let a): a.count
        case .doubles(let a): a.count
        case .bools(let a): a.count
        case .unsupported: nil
        }
    }

    var isAtEnd: Bool {
        switch resolved {
        case .unsupported: false
        default: currentIndex >= (count ?? 0)
        }
    }

    init(
        snapshot: ConfigSnapshotReader,
        codingPath: [any CodingKey],
        userInfo: [CodingUserInfoKey: Any],
        typeDecodingStrategies: [ObjectIdentifier: AnyConfigDecodingStrategy]
    ) {
        self.snapshot = snapshot
        self.codingPath = codingPath
        self.userInfo = userInfo
        self.typeDecodingStrategies = typeDecodingStrategies
        self.resolved = .unsupported
    }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode(_ type: String.Type) throws -> String {
        let array = try resolveStrings()
        try checkBounds(array.count)
        defer { currentIndex += 1 }
        return array[currentIndex]
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let array = try resolveBools()
        try checkBounds(array.count)
        defer { currentIndex += 1 }
        return array[currentIndex]
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        let array = try resolveInts()
        try checkBounds(array.count)
        defer { currentIndex += 1 }
        return array[currentIndex]
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        let array = try resolveDoubles()
        try checkBounds(array.count)
        defer { currentIndex += 1 }
        return array[currentIndex]
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        Float(try decode(Double.self))
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 { try integerElement() }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try integerElement() }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try integerElement() }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try integerElement() }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try integerElement() }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try integerElement() }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try integerElement() }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try integerElement() }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try integerElement() }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == String.self { return try decode(String.self) as! T }
        if type == Int.self { return try decode(Int.self) as! T }
        if type == Double.self { return try decode(Double.self) as! T }
        if type == Bool.self { return try decode(Bool.self) as! T }
        if type == Float.self { return try decode(Float.self) as! T }
        if type == Int8.self { return try decode(Int8.self) as! T }
        if type == Int16.self { return try decode(Int16.self) as! T }
        if type == Int32.self { return try decode(Int32.self) as! T }
        if type == Int64.self { return try decode(Int64.self) as! T }
        if type == UInt.self { return try decode(UInt.self) as! T }
        if type == UInt8.self { return try decode(UInt8.self) as! T }
        if type == UInt16.self { return try decode(UInt16.self) as! T }
        if type == UInt32.self { return try decode(UInt32.self) as! T }
        if type == UInt64.self { return try decode(UInt64.self) as! T }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription:
                    "ConfigSnapshotDecoder does not support decoding arrays of \(T.self). Only arrays of primitive types (String, Int, Double, Bool) are supported."
            )
        )
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "ConfigSnapshotDecoder does not support nested containers inside arrays."
            )
        )
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "ConfigSnapshotDecoder does not support nested arrays."
            )
        )
    }

    func superDecoder() throws -> any Decoder {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "ConfigSnapshotDecoder does not support superDecoder()."
            )
        )
    }

    // MARK: - Private helpers

    private func configKey() -> ConfigKey {
        ConfigKey(codingPath.map(\.stringValue))
    }

    private mutating func resolveStrings() throws -> [String] {
        if case .strings(let a) = resolved { return a }
        let configKey = configKey()
        guard let result = snapshot.stringArray(forKey: configKey) else {
            throw DecodingError.valueNotFound(
                [String].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No string array found for key \"\(configKey)\"."
                )
            )
        }
        resolved = .strings(result)
        return result
    }

    private mutating func resolveInts() throws -> [Int] {
        if case .ints(let a) = resolved { return a }
        let configKey = configKey()
        guard let result = snapshot.intArray(forKey: configKey) else {
            throw DecodingError.valueNotFound(
                [Int].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No int array found for key \"\(configKey)\"."
                )
            )
        }
        resolved = .ints(result)
        return result
    }

    private mutating func resolveDoubles() throws -> [Double] {
        if case .doubles(let a) = resolved { return a }
        let configKey = configKey()
        guard let result = snapshot.doubleArray(forKey: configKey) else {
            throw DecodingError.valueNotFound(
                [Double].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No double array found for key \"\(configKey)\"."
                )
            )
        }
        resolved = .doubles(result)
        return result
    }

    private mutating func resolveBools() throws -> [Bool] {
        if case .bools(let a) = resolved { return a }
        let configKey = configKey()
        guard let result = snapshot.boolArray(forKey: configKey) else {
            throw DecodingError.valueNotFound(
                [Bool].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No bool array found for key \"\(configKey)\"."
                )
            )
        }
        resolved = .bools(result)
        return result
    }

    private mutating func integerElement<T: FixedWidthInteger>() throws -> T {
        let intValue = try decode(Int.self)
        guard let converted = T(exactly: intValue) else {
            throw DecodingError.typeMismatch(
                T.self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Value \(intValue) does not fit in \(T.self)."
                )
            )
        }
        return converted
    }

    private func checkBounds(_ count: Int) throws {
        guard currentIndex < count else {
            throw DecodingError.valueNotFound(
                Any.self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Unkeyed container is at end (index \(currentIndex), count \(count))."
                )
            )
        }
    }
}
