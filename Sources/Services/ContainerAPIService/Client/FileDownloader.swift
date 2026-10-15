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

import AsyncHTTPClient
import ContainerizationError
import ContainerizationExtras
import Darwin
import Foundation
import Synchronization
import TerminalProgress

public struct FileDownloader {
    public static func downloadFile(url: URL, to destination: URL, progressUpdate: ProgressUpdateHandler? = nil) async throws {
        try await downloadFile(url: url, to: destination, progressUpdate: progressUpdate, allowResume: true)
    }

    private static func downloadFile(
        url: URL,
        to destination: URL,
        progressUpdate: ProgressUpdateHandler?,
        allowResume: Bool
    ) async throws {
        let existingSize = try destination.fileSize
        var request = try HTTPClient.Request(url: url)
        if allowResume && existingSize > 0 {
            request.headers.add(name: "Range", value: "bytes=\(existingSize)-")
        }

        let responseHead = Mutex<ResponseHead?>(nil)
        let downloadDestination =
            existingSize > 0
            ? destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).download")
            : destination
        defer {
            if downloadDestination != destination {
                try? FileManager.default.removeItem(at: downloadDestination)
            }
        }

        let delegate = try FileDownloadDelegate(
            path: downloadDestination.path(),
            reportHead: {
                let head = ResponseHead(
                    statusCode: Int($0.status.code),
                    contentRange: $0.headers["Content-Range"].first)
                responseHead.withLock { $0 = head }
                let expectedSizeString = $0.headers["Content-Length"].first ?? ""
                if let expectedSize = Int64(expectedSizeString) {
                    let resumedSize = head.statusCode == 206 ? existingSize : 0
                    if let progressUpdate {
                        Task {
                            await progressUpdate([
                                .addTotalSize(resumedSize + expectedSize)
                            ])
                        }
                    }
                }
            },
            reportProgress: {
                let receivedBytes = Int64($0.receivedBytes)
                if let progressUpdate {
                    let resumedSize = responseHead.withLock { $0?.statusCode == 206 ? existingSize : 0 }
                    Task {
                        await progressUpdate([
                            .setSize(resumedSize + receivedBytes)
                        ])
                    }
                }
            })

        let client = FileDownloader.createClient(url: url)
        do {
            _ = try await client.execute(request: request, delegate: delegate).get()
        } catch {
            try? await client.shutdown()
            if existingSize > 0 {
                let head = responseHead.withLock { $0 }
                try commitDownloadedBytes(
                    from: downloadDestination,
                    to: destination,
                    existingSize: existingSize,
                    responseHead: head,
                    requireCompleteResponse: false)
            }
            throw error
        }
        try await client.shutdown()

        if existingSize > 0 {
            let head = responseHead.withLock { $0 }
            if allowResume, head?.statusCode == 416 {
                try await downloadFile(
                    url: url,
                    to: destination,
                    progressUpdate: progressUpdate,
                    allowResume: false)
                return
            }
            try commitDownloadedBytes(
                from: downloadDestination,
                to: destination,
                existingSize: existingSize,
                responseHead: head,
                requireCompleteResponse: true)
        }
    }

    private struct ResponseHead: Sendable {
        let statusCode: Int
        let contentRange: String?
    }

    private struct ContentRange {
        let expectedLength: Int64
        let isFinal: Bool
    }

    private static func commitDownloadedBytes(
        from source: URL,
        to destination: URL,
        existingSize: Int64,
        responseHead: ResponseHead?,
        requireCompleteResponse: Bool
    ) throws {
        if responseHead?.statusCode == 200 {
            guard requireCompleteResponse else { return }
            if !FileManager.default.fileExists(atPath: source.path) {
                try Data().write(to: source)
            }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
            return
        }
        let downloadedSize = try source.fileSize
        guard downloadedSize > 0 else {
            guard !requireCompleteResponse else {
                throw ContainerizationError(
                    .invalidState,
                    message: "server returned an empty response for resumed download from byte \(existingSize)"
                )
            }
            return
        }
        if responseHead?.statusCode == 206,
            let contentRange = responseHead?.contentRange.flatMap({
                parseContentRange($0, expectedStart: existingSize)
            }),
            downloadedSize == contentRange.expectedLength
                || (!requireCompleteResponse && downloadedSize < contentRange.expectedLength),
            !requireCompleteResponse || contentRange.isFinal
        {
            try append(contentsOf: source, to: destination)
            return
        }
        guard !requireCompleteResponse else {
            throw ContainerizationError(
                .invalidState,
                message: "server returned an invalid response for resumed download from byte \(existingSize)"
            )
        }
    }

    private static func parseContentRange(_ value: String, expectedStart: Int64) -> ContentRange? {
        guard value.hasPrefix("bytes ") else { return nil }
        let components = value.dropFirst("bytes ".count).split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let bounds = components[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false)
        guard
            bounds.count == 2,
            let start = Int64(bounds[0]),
            let end = Int64(bounds[1]),
            start == expectedStart,
            end >= start
        else {
            return nil
        }
        let total = Int64(components[1])
        guard components[1] == "*" || total.map({ $0 > end }) == true else { return nil }
        let (expectedLength, overflow) = (end - start).addingReportingOverflow(1)
        guard !overflow else { return nil }
        return ContentRange(
            expectedLength: expectedLength,
            isFinal: total.map { end == $0 - 1 } ?? false)
    }

    private static func append(contentsOf source: URL, to destination: URL) throws {
        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let destinationHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? destinationHandle.close() }
        while let data = try sourceHandle.read(upToCount: Int(1.mib())), !data.isEmpty {
            try destinationHandle.write(contentsOf: data)
        }
    }

    private static func createClient(url: URL) -> HTTPClient {
        var httpConfiguration = HTTPClient.Configuration()
        // for large file downloads we keep a generous connect timeout, and
        // no read timeout since download durations can vary
        httpConfiguration.timeout = HTTPClient.Configuration.Timeout(
            connect: .seconds(30),
            read: .none
        )
        if let host = url.host {
            let proxyURL = ProxyUtils.proxyFromEnvironment(scheme: url.scheme, host: host)
            if let proxyURL, let proxyHost = proxyURL.host {
                httpConfiguration.proxy = HTTPClient.Configuration.Proxy.server(host: proxyHost, port: proxyURL.port ?? 8080)
            }
        }

        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: httpConfiguration)
    }
}

extension URL {
    fileprivate var fileSize: Int64 {
        get throws {
            var attributes = stat()
            guard Darwin.lstat(path, &attributes) == 0 else {
                if errno == ENOENT {
                    return 0
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard attributes.st_mode & S_IFMT == S_IFREG else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "download destination is not a regular file: \(path)"
                )
            }
            return attributes.st_size
        }
    }
}
