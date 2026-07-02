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
import CryptoKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import TerminalProgress

public struct FileDownloader {
    public static func downloadFile(url: URL, to destination: URL, progressUpdate: ProgressUpdateHandler? = nil) async throws {
        let request = try HTTPClient.Request(url: url)

        let delegate = try FileDownloadDelegate(
            path: destination.path(),
            reportHead: {
                let expectedSizeString = $0.headers["Content-Length"].first ?? ""
                if let expectedSize = Int64(expectedSizeString), let progressUpdate {
                    Task {
                        await progressUpdate([
                            .addTotalSize(expectedSize)
                        ])
                    }
                }
            },
            reportProgress: {
                let receivedBytes = Int64($0.receivedBytes)
                if let progressUpdate {
                    Task {
                        await progressUpdate([
                            .setSize(receivedBytes)
                        ])
                    }
                }
            })

        let client = FileDownloader.createClient(url: url)
        do {
            _ = try await client.execute(request: request, delegate: delegate).get()
        } catch {
            try? await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }

    public static func downloadFile(
        url: URL,
        to destination: URL,
        progressUpdate: ProgressUpdateHandler? = nil,
        computingSHA256: Bool
    ) async throws -> String? {
        guard computingSHA256 else {
            try await downloadFile(url: url, to: destination, progressUpdate: progressUpdate)
            return nil
        }

        let request = try HTTPClient.Request(url: url)
        let fileIOThreadPool = NIOThreadPool(numberOfThreads: 1)
        fileIOThreadPool.start()

        let delegate = try HashingFileDownloadDelegate(
            path: destination.path(),
            pool: fileIOThreadPool,
            computingSHA256: computingSHA256,
            reportHead: {
                let expectedSizeString = $0.headers["Content-Length"].first ?? ""
                if let expectedSize = Int64(expectedSizeString), let progressUpdate {
                    Task {
                        await progressUpdate([
                            .addTotalSize(expectedSize)
                        ])
                    }
                }
            },
            reportProgress: {
                let receivedBytes = Int64($0.receivedBytes)
                if let progressUpdate {
                    Task {
                        await progressUpdate([
                            .setSize(receivedBytes)
                        ])
                    }
                }
            })

        let client = FileDownloader.createClient(url: url)
        do {
            let response = try await client.execute(request: request, delegate: delegate).get()
            try await client.shutdown()
            await FileDownloader.shutdown(fileIOThreadPool)
            return response.sha256Digest
        } catch {
            try? await client.shutdown()
            await FileDownloader.shutdown(fileIOThreadPool)
            throw error
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

    private static func shutdown(_ threadPool: NIOThreadPool) async {
        await withCheckedContinuation { continuation in
            threadPool.shutdownGracefully { _ in
                continuation.resume()
            }
        }
    }
}

// Mirrors AsyncHTTPClient's file download delegate while updating an optional
// SHA-256 hasher from the same response chunks that are written to disk.
private final class HashingFileDownloadDelegate: @unchecked Sendable, HTTPClientResponseDelegate {
    struct Progress: Sendable {
        var totalBytes: Int?
        var receivedBytes: Int
    }

    struct Response: Sendable {
        var progress: Progress
        var sha256Digest: String?
    }

    private struct State {
        var progress = Progress(totalBytes: nil, receivedBytes: 0)
        var fileHandleFuture: EventLoopFuture<NIOFileHandle>?
        var writeFuture: EventLoopFuture<Void>?
        var sha256: SHA256?
    }

    private let filePath: String
    private let fileIOThreadPool: NIOThreadPool
    private let reportHead: (@Sendable (HTTPResponseHead) -> Void)?
    private let reportProgress: (@Sendable (Progress) -> Void)?
    private let lock = NSLock()
    private var state: State

    init(
        path: String,
        pool: NIOThreadPool,
        computingSHA256: Bool,
        reportHead: (@Sendable (HTTPResponseHead) -> Void)? = nil,
        reportProgress: (@Sendable (Progress) -> Void)? = nil
    ) throws {
        self.filePath = path
        self.fileIOThreadPool = pool
        self.reportHead = reportHead
        self.reportProgress = reportProgress
        self.state = State(sha256: computingSHA256 ? SHA256() : nil)
    }

    func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        withState {
            if let totalBytesString = head.headers.first(name: "Content-Length"),
                let totalBytes = Int(totalBytesString)
            {
                $0.progress.totalBytes = totalBytes
            }
        }
        reportHead?(head)
        return task.eventLoop.makeSucceededFuture(())
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        buffer.withUnsafeReadableBytes { readableBytes in
            withState {
                $0.sha256?.update(bufferPointer: readableBytes)
            }
        }

        let (progress, io) = withState { state in
            let io = NonBlockingFileIO(threadPool: fileIOThreadPool)
            state.progress.receivedBytes += buffer.readableBytes
            return (state.progress, io)
        }
        reportProgress?(progress)

        let writeFuture = withState { state in
            let writeFuture: EventLoopFuture<Void>
            if let fileHandleFuture = state.fileHandleFuture {
                writeFuture = fileHandleFuture.flatMap {
                    io.write(fileHandle: $0, buffer: buffer, eventLoop: task.eventLoop)
                }
            } else {
                let fileHandleFuture = io.openFile(
                    _deprecatedPath: filePath,
                    mode: .write,
                    flags: .allowFileCreation(),
                    eventLoop: task.eventLoop
                )
                state.fileHandleFuture = fileHandleFuture
                writeFuture = fileHandleFuture.flatMap {
                    io.write(fileHandle: $0, buffer: buffer, eventLoop: task.eventLoop)
                }
            }

            state.writeFuture = writeFuture
            return writeFuture
        }

        return writeFuture
    }

    func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {
        finalize()
    }

    func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
        finalize()
        return withState { state in
            let digest = state.sha256?.finalize().map { String(format: "%02x", $0) }.joined()
            return Response(progress: state.progress, sha256Digest: digest)
        }
    }

    private func close(fileHandle: NIOFileHandle) {
        try! fileHandle.close()
        withState {
            $0.fileHandleFuture = nil
        }
    }

    private func finalize() {
        enum Finalize {
            case writeFuture(EventLoopFuture<Void>)
            case fileHandleFuture(EventLoopFuture<NIOFileHandle>)
            case none
        }

        let finalize = withState { state in
            if let writeFuture = state.writeFuture {
                return Finalize.writeFuture(writeFuture)
            } else if let fileHandleFuture = state.fileHandleFuture {
                return Finalize.fileHandleFuture(fileHandleFuture)
            } else {
                return Finalize.none
            }
        }

        switch finalize {
        case .writeFuture(let future):
            future.whenComplete { _ in
                let fileHandleFuture = self.withState { state in
                    let future = state.fileHandleFuture
                    state.fileHandleFuture = nil
                    state.writeFuture = nil
                    return future
                }

                fileHandleFuture?.whenSuccess {
                    self.close(fileHandle: $0)
                }
            }
        case .fileHandleFuture(let future):
            future.whenSuccess { self.close(fileHandle: $0) }
        case .none:
            ()
        }
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
