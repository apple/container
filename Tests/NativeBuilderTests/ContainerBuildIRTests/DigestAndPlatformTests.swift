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

import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerBuildIR

struct DigestAndPlatformTests {

    // MARK: - Digest Algorithm Tests

    @Test func digestSHA256Creation() throws {
        let data = "Hello, World!".data(using: .utf8)!
        let digest = try Digest.compute(data, using: .sha256)

        #expect(digest.algorithm == .sha256)
        #expect(digest.bytes.count == 32)  // SHA256 produces 32 bytes

        // Verify deterministic computation
        let digest2 = try Digest.compute(data, using: .sha256)
        #expect(digest == digest2)

        // Verify string format
        let stringValue = digest.stringValue
        #expect(stringValue.hasPrefix("sha256:"))
        #expect(stringValue.count == "sha256:".count + 64)  // 32 bytes = 64 hex chars
    }

    @Test func digestSHA384Creation() throws {
        let data = "Test data for SHA384".data(using: .utf8)!
        let digest = try Digest.compute(data, using: .sha384)

        #expect(digest.algorithm == .sha384)
        #expect(digest.bytes.count == 48)  // SHA384 produces 48 bytes

        // Verify string format
        let stringValue = digest.stringValue
        #expect(stringValue.hasPrefix("sha384:"))
        #expect(stringValue.count == "sha384:".count + 96)  // 48 bytes = 96 hex chars
    }

    @Test func digestSHA512Creation() throws {
        let data = "Test data for SHA512".data(using: .utf8)!
        let digest = try Digest.compute(data, using: .sha512)

        #expect(digest.algorithm == .sha512)
        #expect(digest.bytes.count == 64)  // SHA512 produces 64 bytes

        // Verify string format
        let stringValue = digest.stringValue
        #expect(stringValue.hasPrefix("sha512:"))
        #expect(stringValue.count == "sha512:".count + 128)  // 64 bytes = 128 hex chars
    }

    @Test func digestFromValidBytes() throws {
        // Create SHA256 digest from valid bytes
        let validBytes = Data(repeating: 0xAB, count: 32)
        let digest = try Digest(algorithm: .sha256, bytes: validBytes)

        #expect(digest.algorithm == .sha256)
        #expect(digest.bytes == validBytes)

        let expectedString = "sha256:" + String(repeating: "ab", count: 32)
        #expect(digest.stringValue == expectedString)
    }

    @Test func digestFromInvalidBytes() throws {
        // Test wrong length for SHA256
        let wrongLengthBytes = Data(repeating: 0xFF, count: 16)  // Should be 32
        #expect(throws: DigestError.self) {
            try Digest(algorithm: .sha256, bytes: wrongLengthBytes)
        }

        // Test wrong length for SHA384
        let wrongLengthBytes384 = Data(repeating: 0xFF, count: 32)  // Should be 48
        #expect(throws: DigestError.self) {
            try Digest(algorithm: .sha384, bytes: wrongLengthBytes384)
        }

        // Test wrong length for SHA512
        let wrongLengthBytes512 = Data(repeating: 0xFF, count: 32)  // Should be 64
        #expect(throws: DigestError.self) {
            try Digest(algorithm: .sha512, bytes: wrongLengthBytes512)
        }
    }

    // MARK: - Digest Parsing Tests

    @Test func digestParsingValidFormats() throws {
        let testCases = [
            ("sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", Digest.Algorithm.sha256),
            ("sha384:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", Digest.Algorithm.sha384),
            ("sha512:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", Digest.Algorithm.sha512),
        ]

        for (digestString, expectedAlgorithm) in testCases {
            let digest = try Digest(parsing: digestString)
            #expect(digest.algorithm == expectedAlgorithm)
            #expect(digest.stringValue == digestString)
        }
    }

    @Test func digestParsingInvalidFormats() throws {
        let invalidFormats = [
            "no-colon-separator",
            "sha256",
            "sha256:",
            "sha256:invalid-hex",
            "sha256:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",  // Invalid hex chars
            "unknown:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
            "sha256:short",  // Too short
            "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789extra",  // Too long
        ]

        for invalidFormat in invalidFormats {
            #expect(throws: DigestError.self) {
                try Digest(parsing: invalidFormat)
            }
        }
    }

    @Test func digestParsingMixedCase() throws {
        // Test that mixed case hex is handled correctly
        let upperCaseDigest = "sha256:ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"
        let lowerCaseDigest = "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let mixedCaseDigest = "sha256:AbCdEf0123456789aBcDeF0123456789AbCdEf0123456789aBcDeF0123456789"

        let upperDigest = try Digest(parsing: upperCaseDigest)
        let lowerDigest = try Digest(parsing: lowerCaseDigest)
        let mixedDigest = try Digest(parsing: mixedCaseDigest)

        // All should parse to the same bytes
        #expect(upperDigest.bytes == lowerDigest.bytes)
        #expect(lowerDigest.bytes == mixedDigest.bytes)

        // String output should be lowercase
        #expect(upperDigest.stringValue == lowerCaseDigest)
        #expect(mixedDigest.stringValue == lowerCaseDigest)
    }

    // MARK: - Digest Content Hashing Tests

    @Test func digestContentHashing() throws {
        // Test that different content produces different digests
        let content1 = "First piece of content".data(using: .utf8)!
        let content2 = "Second piece of content".data(using: .utf8)!

        let digest1 = try Digest.compute(content1)
        let digest2 = try Digest.compute(content2)

        #expect(digest1 != digest2)
        #expect(digest1.stringValue != digest2.stringValue)

        // Test that same content produces same digest
        let digest1Copy = try Digest.compute(content1)
        #expect(digest1 == digest1Copy)
    }

    @Test func digestEmptyContent() throws {
        let emptyData = Data()
        let digest = try Digest.compute(emptyData)

        #expect(digest.algorithm == .sha256)  // Default algorithm
        #expect(digest.bytes.count == 32)

        // Known SHA256 of empty string
        let expectedEmptyDigest = try Digest(parsing: "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(digest == expectedEmptyDigest)
    }

    @Test func digestLargeContent() throws {
        // Test with larger content (1MB)
        let largeContent = Data(repeating: 0x42, count: 1024 * 1024)
        let digest = try Digest.compute(largeContent)

        #expect(digest.algorithm == .sha256)
        #expect(digest.bytes.count == 32)

        // Verify deterministic
        let digest2 = try Digest.compute(largeContent)
        #expect(digest == digest2)
    }

    // MARK: - Digest Codable Tests

    @Test func digestCodable() throws {
        let originalDigest = try Digest(parsing: "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")

        // Encode to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalDigest)

        // Decode from JSON
        let decoder = JSONDecoder()
        let decodedDigest = try decoder.decode(Digest.self, from: data)

        #expect(decodedDigest == originalDigest)
        #expect(decodedDigest.stringValue == originalDigest.stringValue)
    }

    // MARK: - Integration Tests

    @Test func digestAndPlatformIntegration() throws {
        // Test that digests and platforms work together in realistic scenarios
        let platform = Platform.linuxAMD64
        let operationData = "RUN apt-get update && apt-get install -y curl".data(using: .utf8)!
        let operationDigest = try Digest.compute(operationData)

        // Simulate cache key generation (simplified)
        let cacheKeyData = "\(operationDigest.stringValue):\(platform.description)".data(using: .utf8)!
        let cacheDigest = try Digest.compute(cacheKeyData)

        #expect(cacheDigest.algorithm == .sha256)
        #expect(cacheDigest.bytes.count == 32)

        // Different platform should produce different cache key
        let differentPlatform = Platform.linuxARM64
        let differentCacheKeyData = "\(operationDigest.stringValue):\(differentPlatform.description)".data(using: .utf8)!
        let differentCacheDigest = try Digest.compute(differentCacheKeyData)

        #expect(cacheDigest != differentCacheDigest)
    }

    @Test func multiAlgorithmDigestComparison() throws {
        let testData = "Container build test data".data(using: .utf8)!

        let sha256Digest = try Digest.compute(testData, using: .sha256)
        let sha384Digest = try Digest.compute(testData, using: .sha384)
        let sha512Digest = try Digest.compute(testData, using: .sha512)

        // All should be different (different algorithms)
        #expect(sha256Digest != sha384Digest)
        #expect(sha384Digest != sha512Digest)
        #expect(sha256Digest != sha512Digest)

        // Verify byte lengths
        #expect(sha256Digest.bytes.count == 32)
        #expect(sha384Digest.bytes.count == 48)
        #expect(sha512Digest.bytes.count == 64)

        // Verify string prefixes
        #expect(sha256Digest.stringValue.hasPrefix("sha256:"))
        #expect(sha384Digest.stringValue.hasPrefix("sha384:"))
        #expect(sha512Digest.stringValue.hasPrefix("sha512:"))
    }

    // MARK: - Error Message Tests

    @Test func digestErrorMessages() throws {
        do {
            try Digest(algorithm: .sha256, bytes: Data(count: 16))
            Issue.record("Should have thrown an error")
        } catch let error as DigestError {
            switch error {
            case .invalidLength(let expected, let actual):
                #expect(expected == 32)
                #expect(actual == 16)
                #expect(error.errorDescription?.contains("expected 32") == true)
                #expect(error.errorDescription?.contains("got 16") == true)
            default:
                Issue.record("Wrong error type: \(error)")
            }
        }

        do {
            try Digest(parsing: "invalid:format")
            Issue.record("Should have thrown an error")
        } catch let error as DigestError {
            switch error {
            case .unsupportedAlgorithm(let algo):
                #expect(algo == "invalid")
                #expect(error.errorDescription?.contains("Unsupported digest algorithm") == true)
            default:
                Issue.record("Wrong error type: \(error)")
            }
        }

        do {
            try Digest(parsing: "sha256:invalid-hex")
            Issue.record("Should have thrown an error")
        } catch let error as DigestError {
            switch error {
            case .invalidHex(let hex):
                #expect(hex == "invalid-hex")
                #expect(error.errorDescription?.contains("Invalid hex") == true)
            default:
                Issue.record("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - Performance Tests

    @Test func digestPerformance() throws {
        let testSizes = [1024, 10240, 102400]  // 1KB, 10KB, 100KB

        for size in testSizes {
            let data = Data(repeating: 0x42, count: size)

            let startTime = Date()
            let _ = try Digest.compute(data)
            let duration = Date().timeIntervalSince(startTime)

            print("Digest computation for \(size) bytes: \(String(format: "%.3f", duration))s")
            #expect(duration < 0.1, "Digest computation should be fast for \(size) bytes")
        }
    }
}
