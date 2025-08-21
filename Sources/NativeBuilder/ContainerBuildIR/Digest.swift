//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import Crypto
import Foundation

/// A content-addressed identifier for build artifacts.
///
/// Design rationale:
/// - Immutable value type ensures digests cannot be modified after creation
/// - Strong typing prevents mixing different hash algorithms
/// - Validates format on creation to catch errors early
/// - Supports common container ecosystem digest formats
public struct Digest: Hashable, Sendable {
    /// The algorithm used to compute this digest
    public enum Algorithm: String, CaseIterable, Sendable {
        case sha256
        case sha384
        case sha512

        /// Expected byte length for this algorithm
        var byteLength: Int {
            switch self {
            case .sha256: return 32
            case .sha384: return 48
            case .sha512: return 64
            }
        }
    }

    public let algorithm: Algorithm
    public let bytes: Data

    /// Create a digest from raw bytes
    /// - Throws: If bytes length doesn't match algorithm requirements
    public init(algorithm: Algorithm, bytes: Data) throws {
        guard bytes.count == algorithm.byteLength else {
            throw DigestError.invalidLength(expected: algorithm.byteLength, actual: bytes.count)
        }
        self.algorithm = algorithm
        self.bytes = bytes
    }

    /// Create a digest from a hex string (e.g., "sha256:abc123...")
    public init(parsing string: String) throws {
        let components = string.split(separator: ":", maxSplits: 1)
        guard components.count == 2 else {
            throw DigestError.invalidFormat(string)
        }

        guard let algorithm = Algorithm(rawValue: String(components[0])) else {
            throw DigestError.unsupportedAlgorithm(String(components[0]))
        }

        guard let bytes = Data(hexString: String(components[1])) else {
            throw DigestError.invalidHex(String(components[1]))
        }

        try self.init(algorithm: algorithm, bytes: bytes)
    }

    /// String representation in standard format (e.g., "sha256:abc123...")
    public var stringValue: String {
        "\(algorithm.rawValue):\(bytes.hexString)"
    }

    /// Compute digest of data
    /// - Throws: DigestError.cryptoInternalError if Crypto produces unexpected results
    public static func compute(_ data: Data, using algorithm: Algorithm = .sha256) throws -> Digest {
        let bytes: Data
        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            hasher.update(data: data)
            bytes = Data(hasher.finalize())
        case .sha384:
            var hasher = SHA384()
            hasher.update(data: data)
            bytes = Data(hasher.finalize())
        case .sha512:
            var hasher = SHA512()
            hasher.update(data: data)
            bytes = Data(hasher.finalize())
        }

        // This should never fail as Crypto produces the correct byte length
        // But we handle it gracefully for production safety
        do {
            return try Digest(algorithm: algorithm, bytes: bytes)
        } catch {
            // This should never happen in practice, but we provide proper error handling
            throw DigestError.cryptoInternalError("Crypto produced digest with incorrect length for \(algorithm): \(error)")
        }
    }
}

extension Digest: CustomStringConvertible {
    public var description: String { stringValue }
}

extension Digest: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        try self.init(parsing: string)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

public enum DigestError: LocalizedError {
    case invalidFormat(String)
    case unsupportedAlgorithm(String)
    case invalidHex(String)
    case invalidLength(expected: Int, actual: Int)
    case cryptoInternalError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let string):
            return "Invalid digest format: '\(string)'. Expected 'algorithm:hex'."
        case .unsupportedAlgorithm(let algo):
            return "Unsupported digest algorithm: '\(algo)'"
        case .invalidHex(let hex):
            return "Invalid hex string: '\(hex)'"
        case .invalidLength(let expected, let actual):
            return "Invalid digest length: expected \(expected) bytes, got \(actual)"
        case .cryptoInternalError(let details):
            return "Crypto internal error: \(details)"
        }
    }
}

// MARK: - Utility Extensions

extension Data {
    fileprivate init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }

        var data = Data(capacity: hexString.count / 2)

        for i in stride(from: 0, to: hexString.count, by: 2) {
            let startIndex = hexString.index(hexString.startIndex, offsetBy: i)
            let endIndex = hexString.index(startIndex, offsetBy: 2)
            let hexByte = hexString[startIndex..<endIndex]

            guard let byte = UInt8(hexByte, radix: 16) else { return nil }
            data.append(byte)
        }

        self = data
    }

    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
