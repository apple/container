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

import Darwin
import Foundation
import Logging
import SystemPackage
import Testing

@testable import MachineAPIService

@Suite("Published machine sockets")
struct PublishedSocketTests {
    @Test
    func staleSocketIsRemoved() throws {
        try withTemporarySocketPath { path in
            let socket = try boundSocket(at: path)
            Darwin.close(socket)

            try preparePublishedSocket(path: path)

            #expect(!FileManager.default.fileExists(atPath: path.string))
        }
    }

    @Test
    func activeSocketIsPreserved() throws {
        try withTemporarySocketPath { path in
            let socket = try boundSocket(at: path)
            defer { Darwin.close(socket) }
            #expect(Darwin.listen(socket, 1) == 0)

            #expect(throws: Error.self) {
                try preparePublishedSocket(path: path)
            }
            #expect(FileManager.default.fileExists(atPath: path.string))
        }
    }

    @Test
    func nonSocketAndSymlinkArePreserved() throws {
        try withTemporarySocketPath { path in
            try Data().write(to: URL(filePath: path.string))
            #expect(throws: Error.self) {
                try preparePublishedSocket(path: path)
            }
            #expect(FileManager.default.fileExists(atPath: path.string))
        }

        try withTemporarySocketPath { path in
            #expect(symlink("/tmp", path.string) == 0)
            #expect(throws: Error.self) {
                try preparePublishedSocket(path: path)
            }
            var stat = Darwin.stat()
            #expect(lstat(path.string, &stat) == 0)
            #expect((stat.st_mode & S_IFMT) == S_IFLNK)
        }
    }

    @Test
    func cleanupRemovesOnlyStaleSockets() throws {
        let log = Logger(label: "published-socket-test")
        try withTemporarySocketPath { path in
            let socket = try boundSocket(at: path)
            Darwin.close(socket)

            cleanupPublishedSocket(path: path, log: log)

            #expect(!FileManager.default.fileExists(atPath: path.string))
        }

        try withTemporarySocketPath { path in
            let socket = try boundSocket(at: path)
            defer { Darwin.close(socket) }
            #expect(Darwin.listen(socket, 1) == 0)

            cleanupPublishedSocket(path: path, log: log)

            #expect(FileManager.default.fileExists(atPath: path.string))
        }
    }

    @Test
    func replacementBeforeClaimIsRestored() throws {
        try withTemporarySocketPath { path in
            let staleSocket = try boundSocket(at: path)
            defer { Darwin.close(staleSocket) }
            let parentFD = try openSecureDirectory(path.removingLastComponent(), create: false)
            defer { Darwin.close(parentFD) }
            let name = try #require(path.lastComponent?.string)
            var replacementSocket: Int32 = -1

            let result = try removeStalePublishedSocket(
                path: path,
                parentFD: parentFD,
                name: name,
                beforeClaim: {
                    #expect(Darwin.unlink(path.string) == 0)
                    replacementSocket = try boundSocket(at: path)
                    #expect(Darwin.listen(replacementSocket, 1) == 0)
                }
            )
            defer { if replacementSocket >= 0 { Darwin.close(replacementSocket) } }

            guard case .changed = result else {
                Issue.record("replacement was not reported as changed")
                return
            }
            #expect(isSocketListening(at: path))
        }
    }

    @Test
    func staleSocketNearPathLimitIsRemoved() throws {
        let socketName = "docker.sock"
        let base = "/private/tmp/"
        let pathLimit = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        let uniquePrefix = String(UUID().uuidString.prefix(8))
        let directoryName =
            uniquePrefix
            + String(
                repeating: "a",
                count: pathLimit - base.utf8.count - socketName.utf8.count - uniquePrefix.utf8.count - 1
            )
        let directory = FilePath(base + directoryName)
        let path = directory.appending(socketName)
        try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let socket = try boundSocket(at: path)
        Darwin.close(socket)

        try preparePublishedSocket(path: path)

        #expect(!FileManager.default.fileExists(atPath: path.string))
    }

    @Test
    func concurrentReplacementIsNeverRemoved() throws {
        try withTemporarySocketPath { path in
            let claimedSocket = try boundSocket(at: path)
            defer { Darwin.close(claimedSocket) }
            let parentFD = try openSecureDirectory(path.removingLastComponent(), create: false)
            defer { Darwin.close(parentFD) }
            let name = try #require(path.lastComponent?.string)
            var replacementSocket: Int32 = -1

            do {
                _ = try removeStalePublishedSocket(
                    path: path,
                    parentFD: parentFD,
                    name: name,
                    afterClaim: {
                        #expect(Darwin.listen(claimedSocket, 1) == 0)
                        replacementSocket = try boundSocket(at: path)
                        #expect(Darwin.listen(replacementSocket, 1) == 0)
                    }
                )
                Issue.record("concurrent replacement unexpectedly restored the claimed socket")
            } catch {
                #expect(String(describing: error).contains("remains quarantined"))
            }
            defer { if replacementSocket >= 0 { Darwin.close(replacementSocket) } }

            #expect(isSocketListening(at: path))
        }
    }

    private func withTemporarySocketPath(_ body: (FilePath) throws -> Void) throws {
        let directory = FilePath("/private/tmp/cs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        try body(directory.appending("docker.sock"))
    }

    private func boundSocket(at path: FilePath) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError.fromErrno() }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.string.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + bytes.count + 1)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = POSIXError.fromErrno()
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }
}
