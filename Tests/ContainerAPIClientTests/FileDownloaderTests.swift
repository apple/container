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

import ContainerAPIClient
import ContainerTestSupport
import ContainerizationError
import Foundation
import Testing

struct FileDownloaderTests {
    @Test func resumesExistingPartialDownload() async throws {
        let payload = Data("0123456789".utf8)
        let server = try LoopbackFileServer(serving: payload, supportsRanges: true)
        defer { server.shutdown() }

        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("payload.partial")
            try payload.prefix(4).write(to: destination)

            try await FileDownloader.downloadFile(url: server.url, to: destination)

            #expect(server.rangeHeaders == ["bytes=4-"])
            #expect(try Data(contentsOf: destination) == payload)
        }
    }

    @Test func restartsDownloadWhenServerIgnoresRange() async throws {
        let payload = Data("replacement payload".utf8)
        let server = try LoopbackFileServer(serving: payload)
        defer { server.shutdown() }

        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("payload.partial")
            try Data("stale".utf8).write(to: destination)

            try await FileDownloader.downloadFile(url: server.url, to: destination)

            #expect(server.rangeHeaders == ["bytes=5-"])
            #expect(try Data(contentsOf: destination) == payload)
        }
    }

    @Test func restartsDownloadWhenRangeIsNotSatisfiable() async throws {
        let payload = Data("replacement payload".utf8)
        let server = try LoopbackFileServer(serving: payload, supportsRanges: true)
        defer { server.shutdown() }

        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("payload.partial")
            try Data(repeating: 0xff, count: payload.count).write(to: destination)

            try await FileDownloader.downloadFile(url: server.url, to: destination)

            #expect(server.rangeHeaders == ["bytes=\(payload.count)-"])
            #expect(server.requestCount == 2)
            #expect(try Data(contentsOf: destination) == payload)
        }
    }

    @Test func replacesPartialWithEmptyDownloadWhenServerIgnoresRange() async throws {
        let server = try LoopbackFileServer(serving: Data())
        defer { server.shutdown() }

        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("payload.partial")
            try Data("stale".utf8).write(to: destination)

            try await FileDownloader.downloadFile(url: server.url, to: destination)

            #expect(server.rangeHeaders == ["bytes=5-"])
            #expect(try Data(contentsOf: destination).isEmpty)
        }
    }

    @Test func retainsNewBytesWhenResumedDownloadIsInterrupted() async throws {
        let payload = Data("0123456789".utf8)
        let server = try LoopbackFileServer(
            serving: payload,
            supportsRanges: true,
            disconnectAfterBytes: 3)
        defer { server.shutdown() }

        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("payload.partial")
            try payload.prefix(4).write(to: destination)

            await #expect(throws: (any Error).self) {
                try await FileDownloader.downloadFile(url: server.url, to: destination)
            }

            #expect(server.rangeHeaders == ["bytes=4-"])
            #expect(try Data(contentsOf: destination) == payload.prefix(7))
        }
    }

    @Test func retainsPartialWhenRestartedDownloadIsInterrupted() async throws {
        let payload = Data("replacement payload".utf8)
        let server = try LoopbackFileServer(
            serving: payload,
            disconnectAfterBytes: 3)
        defer { server.shutdown() }

        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("payload.partial")
            let partial = Data("stale".utf8)
            try partial.write(to: destination)

            await #expect(throws: (any Error).self) {
                try await FileDownloader.downloadFile(url: server.url, to: destination)
            }

            #expect(server.rangeHeaders == ["bytes=5-"])
            #expect(try Data(contentsOf: destination) == partial)
        }
    }

    @Test func rejectsMalformedContentRangeWithoutChangingPartialDownload() async throws {
        let payload = Data("0123456789".utf8)
        let server = try LoopbackFileServer(
            serving: payload,
            supportsRanges: true,
            contentRangeOverride: "bytes 4-invalid")
        defer { server.shutdown() }

        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("payload.partial")
            let partial = payload.prefix(4)
            try partial.write(to: destination)

            await #expect(throws: (any Error).self) {
                try await FileDownloader.downloadFile(url: server.url, to: destination)
            }

            #expect(try Data(contentsOf: destination) == partial)
        }
    }

    @Test func rejectsContentRangeWithMismatchedBodyLength() async throws {
        let payload = Data("0123456789".utf8)
        let server = try LoopbackFileServer(
            serving: payload,
            supportsRanges: true,
            contentRangeOverride: "bytes 4-8/10",
            responseByteLimit: 5)
        defer { server.shutdown() }

        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("payload.partial")
            let partial = payload.prefix(4)
            try partial.write(to: destination)

            await #expect(throws: ContainerizationError.self) {
                try await FileDownloader.downloadFile(url: server.url, to: destination)
            }

            #expect(try Data(contentsOf: destination) == partial)
        }
    }

    @Test func rejectsSymlinkDestinationWithoutChangingTarget() async throws {
        let payload = Data("0123456789".utf8)
        let server = try LoopbackFileServer(serving: payload, supportsRanges: true)
        defer { server.shutdown() }

        try await withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("target")
            let original = payload.prefix(4)
            try original.write(to: target)
            let destination = directory.appendingPathComponent("payload.partial")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)

            await #expect(throws: (any Error).self) {
                try await FileDownloader.downloadFile(url: server.url, to: destination)
            }

            #expect(try Data(contentsOf: target) == original)
        }
    }

    @Test func interruptedMalformedContentRangeDoesNotChangePartialDownload() async throws {
        let payload = Data("0123456789".utf8)
        let server = try LoopbackFileServer(
            serving: payload,
            supportsRanges: true,
            disconnectAfterBytes: 3,
            contentRangeOverride: "bytes 4-invalid")
        defer { server.shutdown() }

        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("payload.partial")
            let partial = payload.prefix(4)
            try partial.write(to: destination)

            await #expect(throws: (any Error).self) {
                try await FileDownloader.downloadFile(url: server.url, to: destination)
            }

            #expect(try Data(contentsOf: destination) == partial)
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}
