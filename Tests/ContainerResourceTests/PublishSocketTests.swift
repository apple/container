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
import SystemPackage
import Testing

@testable import ContainerResource

/// Tests covering the custom `Codable` implementation on ``PublishSocket``.
///
/// `containerPath` and `hostPath` were migrated from `URL` to `FilePath`.
/// Because `URL` is encoded by `JSONEncoder` as its `absoluteString` (e.g.
/// `"file:///var/run/docker.sock"`), persisted bundles and any service
/// binaries still typed against `URL` expect that exact byte format on the
/// wire. The tests below pin the encoder to that legacy shape and verify the
/// decoder accepts both the legacy file-URL form and a plain absolute path.
struct PublishSocketTests {
    // MARK: - Encoding

    @Test
    func testEncodeProducesFileURLAbsoluteString() throws {
        let socket = PublishSocket(
            containerPath: FilePath("/var/run/docker.sock"),
            hostPath: FilePath("/Users/me/docker.sock")
        )
        let json = try JSONEncoder().encode(socket)
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let container = try #require(decoded)
        #expect(container["containerPath"] as? String == "file:///var/run/docker.sock")
        #expect(container["hostPath"] as? String == "file:///Users/me/docker.sock")
        #expect(container["permissions"] == nil)
    }

    @Test
    func testEncodeIsByteCompatibleWithLegacyURLEncoding() throws {
        // Pre-migration, these fields were `URL` and JSON-encoded via
        // `URL.absoluteString`. Encoding must produce the exact same bytes
        // for any reader still decoding them as `URL`.
        let containerPath = "/var/run/docker.sock"
        let hostPath = "/Users/me/docker.sock"
        let legacy = LegacyPublishSocket(
            containerPath: URL(fileURLWithPath: containerPath),
            hostPath: URL(fileURLWithPath: hostPath)
        )
        let current = PublishSocket(
            containerPath: FilePath(containerPath),
            hostPath: FilePath(hostPath)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(current) == encoder.encode(legacy))
    }

    @Test
    func testEncodePercentEncodesSpacesAndSpecialCharacters() throws {
        let socket = PublishSocket(
            containerPath: FilePath("/tmp/a b.sock"),
            hostPath: FilePath("/tmp/dir with spaces/sock")
        )
        let json = try JSONEncoder().encode(socket)
        let decoded = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(decoded["containerPath"] as? String == "file:///tmp/a%20b.sock")
        #expect(decoded["hostPath"] as? String == "file:///tmp/dir%20with%20spaces/sock")
    }

    // MARK: - Decoding (canonical / legacy file-URL form)

    @Test
    func testDecodeFileURLForm() throws {
        let json = """
            {"containerPath":"file:///var/run/docker.sock","hostPath":"file:///Users/me/docker.sock"}
            """.data(using: .utf8)!
        let socket = try JSONDecoder().decode(PublishSocket.self, from: json)
        #expect(socket.containerPath == FilePath("/var/run/docker.sock"))
        #expect(socket.hostPath == FilePath("/Users/me/docker.sock"))
        #expect(socket.permissions == nil)
    }

    @Test
    func testDecodeFileURLPercentEncodingIsResolved() throws {
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
    func testDecodeFileURLWithLocalhostHost() throws {
        let json = """
            {"containerPath":"file://localhost/var/run/docker.sock","hostPath":"file:///host.sock"}
            """.data(using: .utf8)!
        let socket = try JSONDecoder().decode(PublishSocket.self, from: json)
        #expect(socket.containerPath == FilePath("/var/run/docker.sock"))
        #expect(socket.hostPath == FilePath("/host.sock"))
    }

    // MARK: - Decoding (forward-compat plain path form)

    @Test
    func testDecodePlainAbsolutePath() throws {
        // Forward-compat: if some other encoder emits a clean path string,
        // accept it rather than rejecting at the boundary.
        let json = """
            {"containerPath":"/var/run/docker.sock","hostPath":"/Users/me/docker.sock"}
            """.data(using: .utf8)!
        let socket = try JSONDecoder().decode(PublishSocket.self, from: json)
        #expect(socket.containerPath == FilePath("/var/run/docker.sock"))
        #expect(socket.hostPath == FilePath("/Users/me/docker.sock"))
    }

    // MARK: - Round-trip

    @Test
    func testRoundTrip() throws {
        let original = PublishSocket(
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
        let json = """
            {"containerPath":"relative/path.sock","hostPath":"/host.sock"}
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

// MARK: - Helpers

/// Mirrors the pre-migration `URL`-typed `PublishSocket` shape, used only to
/// confirm the new encoder produces byte-identical output for any reader
/// still decoding these fields as `URL`.
private struct LegacyPublishSocket: Encodable {
    var containerPath: URL
    var hostPath: URL
    var permissions: FilePermissions?
}
