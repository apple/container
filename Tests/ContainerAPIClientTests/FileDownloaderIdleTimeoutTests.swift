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
import Darwin
import Foundation
import Testing

@testable import ContainerAPIClient

struct FileDownloaderIdleTimeoutTests {
    @Test
    func downloadFailsWhenTheServerNeverResponds() async throws {
        let server = try LoopbackServer { connection in
            connection.discardRequest()
            connection.waitForClose()
        }
        try await expectStalledDownloadToFail(server)
    }

    @Test
    func downloadFailsWhenTheServerStopsPartwayThroughTheBody() async throws {
        let server = try LoopbackServer { connection in
            connection.discardRequest()
            connection.send("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\nConnection: close\r\n\r\n")
            connection.send(String(repeating: "x", count: 1000))
            connection.waitForClose()
        }
        try await expectStalledDownloadToFail(server)
    }

    @Test
    func slowDownloadThatKeepsReceivingDataCompletes() async throws {
        let server = try LoopbackServer { connection in
            connection.discardRequest()
            connection.send("HTTP/1.1 200 OK\r\nContent-Length: 500\r\nConnection: close\r\n\r\n")
            for _ in 0..<5 {
                connection.send(String(repeating: "x", count: 100))
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("test-download-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: destination)
        }

        // The whole transfer takes longer than the idle timeout, but no single gap does.
        try await FileDownloader.downloadFile(
            url: server.url, to: destination, progressUpdate: nil, idleTimeout: .seconds(1))

        #expect(try Data(contentsOf: destination).count == 500)
    }

    private func expectStalledDownloadToFail(_ server: LoopbackServer) async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("test-download-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: destination)
        }

        let started = ContinuousClock.now
        await #expect {
            try await FileDownloader.downloadFile(
                url: server.url, to: destination, progressUpdate: nil, idleTimeout: .seconds(1))
        } throws: { error in
            (error as? ContainerizationError)?.code == .timeout
        }
        #expect(ContinuousClock.now - started < .seconds(30))
    }
}

/// A one-connection HTTP server on the loopback interface that runs the supplied handler
/// against the accepted socket, so a test can send as little or as slowly as it likes.
private final class LoopbackServer: @unchecked Sendable {
    struct Connection {
        let descriptor: Int32

        func discardRequest() {
            var received: [UInt8] = []
            var byte: UInt8 = 0
            while !received.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard recv(descriptor, &byte, 1, 0) == 1 else {
                    return
                }
                received.append(byte)
            }
        }

        func send(_ text: String) {
            let bytes = Array(text.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes {
                    Darwin.send(descriptor, $0.baseAddress, $0.count, 0)
                }
                guard written > 0 else {
                    return
                }
                offset += written
            }
        }

        func waitForClose() {
            var byte: UInt8 = 0
            while recv(descriptor, &byte, 1, 0) > 0 {}
        }
    }

    let url: URL
    private let listener: Int32

    init(handler: @escaping @Sendable (Connection) -> Void) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(listener)
            throw POSIXError(code)
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        self.listener = listener
        self.url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: assigned.sin_port))/kernel.tar")!

        Thread.detachNewThread {
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else {
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            handler(Connection(descriptor: descriptor))
            close(descriptor)
        }
    }

    deinit {
        close(listener)
    }
}
