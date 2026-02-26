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

// TODO: Look for a way that we can make use of the
// bit-fiddling types from ContainerizationExtras, instead
// of copying them here.

/// Errors that can occur during DNS message serialization/deserialization.
public enum DNSBindError: Error, CustomStringConvertible {
    case marshalFailure(type: String, field: String)
    case unmarshalFailure(type: String, field: String)

    public var description: String {
        switch self {
        case .marshalFailure(let type, let field):
            return "failed to marshal \(type).\(field)"
        case .unmarshalFailure(let type, let field):
            return "failed to unmarshal \(type).\(field)"
        }
    }
}

/// Protocol for types that can be serialized to/from a byte buffer.
protocol Bindable: Sendable {
    /// The fixed size of this type in bytes, if applicable.
    static var size: Int { get }

    /// Serialize this value into the buffer at the given offset.
    /// - Returns: The new offset after writing.
    func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int

    /// Deserialize this value from the buffer at the given offset.
    /// - Returns: The new offset after reading.
    mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int
}

extension [UInt8] {
    /// Copy a value into the buffer at the given offset.
    /// - Returns: The new offset after writing, or nil if the buffer is too small.
    package mutating func copyIn<T>(as type: T.Type, value: T, offset: Int = 0) -> Int? {
        let size = MemoryLayout<T>.size
        guard self.count >= size + offset else {
            return nil
        }
        return self.withUnsafeMutableBytes {
            $0.baseAddress?.advanced(by: offset).assumingMemoryBound(to: T.self).pointee = value
            return offset + size
        }
    }

    /// Copy a value out of the buffer at the given offset.
    /// - Returns: A tuple of (new offset, value), or nil if the buffer is too small.
    package func copyOut<T>(as type: T.Type, offset: Int = 0) -> (Int, T)? {
        let size = MemoryLayout<T>.size
        guard self.count >= size + offset else {
            return nil
        }
        return self.withUnsafeBytes {
            guard let value = $0.baseAddress?.advanced(by: offset).assumingMemoryBound(to: T.self).pointee else {
                return nil
            }
            return (offset + size, value)
        }
    }

    /// Copy a byte array into the buffer at the given offset.
    /// - Returns: The new offset after writing, or nil if the buffer is too small.
    package mutating func copyIn(buffer: [UInt8], offset: Int = 0) -> Int? {
        guard offset + buffer.count <= self.count else {
            return nil
        }
        self[offset..<offset + buffer.count] = buffer[0..<buffer.count]
        return offset + buffer.count
    }

    /// Copy bytes out of the buffer into another buffer.
    /// - Returns: The new offset after reading, or nil if the buffer is too small.
    package func copyOut(buffer: inout [UInt8], offset: Int = 0) -> Int? {
        guard offset + buffer.count <= self.count else {
            return nil
        }
        buffer[0..<buffer.count] = self[offset..<offset + buffer.count]
        return offset + buffer.count
    }
}
