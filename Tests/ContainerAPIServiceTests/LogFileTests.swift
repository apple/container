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
import ContainerXPC
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIService

/// Opening a container's log files without touching its bundle.
///
/// `stdio.log` and `vminitd.log` are both created by RuntimeLinux when it bootstraps a
/// container, and only it writes `vminitd.log`, so either can be legitimately absent.
struct LogFileTests {
    private func makeBundleDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A missing log is reported as absent, and nothing is created in the bundle")
    func missingLog() throws {
        let dir = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bootlog = dir.appendingPathComponent("vminitd.log")

        #expect(try ContainersService.openIfPresent(bootlog) == nil)
        #expect(!FileManager.default.fileExists(atPath: bootlog.path))
    }

    @Test("An existing log is read as is")
    func existingLog() throws {
        let dir = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bootlog = dir.appendingPathComponent("vminitd.log")
        try Data("booted\n".utf8).write(to: bootlog)

        let handle = try #require(try ContainersService.openIfPresent(bootlog))
        #expect(try handle.readToEnd() == Data("booted\n".utf8))
    }

    @Test("Failures other than a missing file still throw")
    func unreadableLog() throws {
        let dir = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bootlog = dir.appendingPathComponent("vminitd.log")
        try Data("secret\n".utf8).write(to: bootlog)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bootlog.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bootlog.path) }

        #expect(throws: POSIXError.self) {
            try ContainersService.openIfPresent(bootlog)
        }
    }

    @Test("A log that is a symlink is refused, not followed")
    func symlinkedLogIsRefused() throws {
        let dir = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appendingPathComponent("secret.txt")
        try Data("not a log\n".utf8).write(to: secret)
        let stdio = dir.appendingPathComponent("stdio.log")
        try FileManager.default.createSymbolicLink(at: stdio, withDestinationURL: secret)

        #expect(throws: POSIXError.self) {
            try ContainersService.openIfPresent(stdio)
        }
    }

    @Test("A dangling symlink is an error, not an empty log")
    func danglingSymlinkIsAnError() throws {
        let dir = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bootlog = dir.appendingPathComponent("vminitd.log")
        try FileManager.default.createSymbolicLink(
            at: bootlog, withDestinationURL: dir.appendingPathComponent("nowhere"))

        #expect(throws: POSIXError.self) {
            try ContainersService.openIfPresent(bootlog)
        }
    }

    @Test("The stand-in for a missing log reads as empty")
    func emptyLogReadsEmpty() throws {
        #expect(try ContainersService.emptyLog().readToEnd() == nil)
    }

    @Test("The stand-in survives the XPC reply, which FileHandle.nullDevice doesn't")
    func emptyLogCrossesXPC() throws {
        // logs(id:) replies with [stdio, boot log] over XPC, and the client's fileHandles(key:)
        // dups both, returning nil if either fd is -1. Two handles, as in the real reply.
        func roundTrip(_ bootLog: FileHandle) throws -> [FileHandle]? {
            let message = XPCMessage(route: .containerLogs)
            try message.set(key: "logs", value: [try ContainersService.emptyLog(), bootLog])
            return message.fileHandles(key: "logs")
        }

        #expect(try roundTrip(try ContainersService.emptyLog())?.count == 2)
        // nullDevice has no descriptor: fileDescriptor is -1, it dups to -1, and the client
        // gets no handles at all, so `container logs` would still fail.
        #expect(FileHandle.nullDevice.fileDescriptor == -1)
        #expect(try roundTrip(FileHandle.nullDevice) == nil)
    }
}
