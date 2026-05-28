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

import ContainerizationError
import Foundation
import SystemPackage
import Testing

@testable import ContainerResource

/// Tests covering the custom `Codable` implementation and validating
/// initializer on ``PublishSocket``.
///
/// `containerPath` and `hostPath` were migrated from `URL` to `FilePath`. The
/// wire format was simultaneously changed from `URL.absoluteString`
/// (e.g. `"file:///var/run/docker.sock"`) to the plain absolute path string
/// (e.g. `"/var/run/docker.sock"`). The decoder retains compatibility with
/// the legacy file-URL form so persisted bundles from earlier releases
/// continue to load.
struct PublishSocketTests {
    // MARK: - init validation

    @Test
    func testInitAcceptsAbsolutePaths() throws {
        let socket = try PublishSocket(
            containerPath: FilePath("/var/run/docker.sock"),
            hostPath: FilePath("/Users/me/docker.sock")
        )
        #expect(socket.containerPath == FilePath("/var/run/docker.sock"))
        #expect(socket.hostPath == FilePath("/Users/me/docker.sock"))
        #expect(socket.permissions == nil)
    }

    @Test
    func testInitRejectsRelativeContainerPath() {
        #expect(throws: ContainerizationError.self) {
            try PublishSocket(
                containerPath: FilePath("relative/path.sock"),
                hostPath: FilePath("/host.sock")
            )
        }
    }

    @Test
    func testInitRejectsRelativeHostPath() {
        #expect(throws: ContainerizationError.self) {
            try PublishSocket(
                containerPath: FilePath("/var/run/docker.sock"),
                hostPath: FilePath("relative/host.sock")
            )
        }
    }

    // MARK: - Encoding (plain absolute path)

    @Test
    func testEncodeProducesPlainAbsolutePath() throws {
        let socket = try PublishSocket(
            containerPath: FilePath("/var/run/docker.sock"),
            hostPath: FilePath("/Users/me/docker.sock")
        )
        let json = try JSONEncoder().encode(socket)
        let decoded = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(decoded["containerPath"] as? String == "/var/run/docker.sock")
        #expect(decoded["hostPath"] as? String == "/Users/me/docker.sock")
        #expect(decoded["permissions"] == nil)
    }

    @Test
    func testEncodeDoesNotPercentEncode() throws {
        // Plain-path encoding preserves spaces and special characters verbatim
        // (no URL percent-encoding layer).
        let socket = try PublishSocket(
            containerPath: FilePath("/tmp/a b.sock"),
            hostPath: FilePath("/tmp/dir with spaces/sock")
        )
        let json = try JSONEncoder().encode(socket)
        let decoded = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(decoded["containerPath"] as? String == "/tmp/a b.sock")
        #expect(decoded["hostPath"] as? String == "/tmp/dir with spaces/sock")
    }

    // MARK: - Decoding (canonical plain-path form)

    @Test
    func testDecodePlainAbsolutePath() throws {
        let json = """
            {"containerPath":"/var/run/docker.sock","hostPath":"/Users/me/docker.sock"}
            """.data(using: .utf8)!
        let socket = try JSONDecoder().decode(PublishSocket.self, from: json)
        #expect(socket.containerPath == FilePath("/var/run/docker.sock"))
        #expect(socket.hostPath == FilePath("/Users/me/docker.sock"))
    }

    // MARK: - Decoding (legacy file-URL form, compat)

    @Test
    func testDecodeLegacyFileURLForm() throws {
        let json = """
            {"containerPath":"file:///var/run/docker.sock","hostPath":"file:///Users/me/docker.sock"}
            """.data(using: .utf8)!
        let socket = try JSONDecoder().decode(PublishSocket.self, from: json)
        #expect(socket.containerPath == FilePath("/var/run/docker.sock"))
        #expect(socket.hostPath == FilePath("/Users/me/docker.sock"))
        #expect(socket.permissions == nil)
    }

    @Test
    func testDecodeLegacyFileURLResolvesPercentEncoding() throws {
        // Persisted bundles created via `URL(fileURLWithPath:)` percent-encode
        // spaces; decoding must yield the original literal path.
        let json = """
            {"containerPath":"file:///tmp/a%20b.sock","hostPath":"file:///tmp/x%2Fy.sock"}
            """.data(using: .utf8)!
        let socket = try JSONDecoder().decode(PublishSocket.self, from: json)
        #expect(socket.containerPath == FilePath("/tmp/a b.sock"))
        // `%2F` decodes to a literal `/` inside the path component.
        #expect(socket.hostPath == FilePath("/tmp/x/y.sock"))
    }

    @Test
    func testDecodeLegacyFileURLWithLocalhostHost() throws {
        let json = """
            {"containerPath":"file://localhost/var/run/docker.sock","hostPath":"file:///host.sock"}
            """.data(using: .utf8)!
        let socket = try JSONDecoder().decode(PublishSocket.self, from: json)
        #expect(socket.containerPath == FilePath("/var/run/docker.sock"))
        #expect(socket.hostPath == FilePath("/host.sock"))
    }

    // MARK: - Round-trip

    @Test
    func testRoundTrip() throws {
        let original = try PublishSocket(
            containerPath: FilePath("/var/run/docker.sock"),
            hostPath: FilePath("/tmp/socket with spaces.sock"),
            permissions: FilePermissions(rawValue: 0o660)
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PublishSocket.self, from: data)
        #expect(decoded.containerPath == original.containerPath)
        #expect(decoded.hostPath == original.hostPath)
        #expect(decoded.permissions == original.permissions)
    }

    // MARK: - Decoding errors

    @Test
    func testDecodeEmptyStringThrows() {
        let json = """
            {"containerPath":"","hostPath":"/host.sock"}
            """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PublishSocket.self, from: json)
        }
    }

    @Test
    func testDecodeFileColonOnlyThrows() {
        // `"file:"` parses as a URL but yields an empty path; reject loudly
        // rather than silently producing `FilePath("")`.
        let json = """
            {"containerPath":"file:","hostPath":"/host.sock"}
            """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PublishSocket.self, from: json)
        }
    }

    @Test
    func testDecodeFileSchemeNoPathThrows() {
        let json = """
            {"containerPath":"file://","hostPath":"/host.sock"}
            """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PublishSocket.self, from: json)
        }
    }

    @Test
    func testDecodeRelativePathThrows() {
        // Reject non-absolute paths. `decodePath` validates absoluteness at the
        // decode layer (and `init` enforces it by construction), surfacing the
        // failure as a `DecodingError`.
        let json = """
            {"containerPath":"relative/path.sock","hostPath":"/host.sock"}
            """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PublishSocket.self, from: json)
        }
    }

    @Test
    func testDecodeRelativeHostPathThrows() {
        // A relative `hostPath` is likewise rejected at the decode layer.
        let json = """
            {"containerPath":"/var/run/docker.sock","hostPath":"relative/host.sock"}
            """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PublishSocket.self, from: json)
        }
    }

    @Test
    func testDecodeNonLocalHostFileURLThrows() {
        // file URLs with a non-empty / non-localhost host are unsafe to
        // interpret as a local path.
        let json = """
            {"containerPath":"file://example.com/etc/passwd","hostPath":"/host.sock"}
            """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PublishSocket.self, from: json)
        }
    }

    @Test
    func testDecodeMissingRequiredKeyThrows() {
        let json = """
            {"hostPath":"/host.sock"}
            """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PublishSocket.self, from: json)
        }
    }
}
