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

import ContainerXPC
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct XPCMessageTests {
    @Test("Repeatedly reading log handles closes the returned descriptors")
    func repeatedLogFileHandlesDoNotLeak() throws {
        let sources = [
            try #require(FileHandle(forReadingAtPath: "/dev/null")),
            try #require(FileHandle(forReadingAtPath: "/dev/null")),
        ]
        defer { sources.forEach { try? $0.close() } }

        let message = XPCMessage(route: "logs")
        try message.set(key: "logs", value: sources)

        for _ in 0..<100 {
            let descriptors: [Int32] = autoreleasepool {
                var handles: [FileHandle]? = message.fileHandles(key: "logs")!
                defer { handles = nil }
                return handles!.map(\.fileDescriptor)
            }
            assertDescriptorsAreClosed(descriptors)
        }
    }

    @Test("Repeatedly reading a dial handle closes the returned descriptor")
    func repeatedDialFileHandleDoesNotLeak() throws {
        let source = try #require(FileHandle(forReadingAtPath: "/dev/null"))
        defer { try? source.close() }

        let message = XPCMessage(route: "dial")
        message.set(key: "fd", value: source)

        for _ in 0..<100 {
            let descriptor: Int32 = autoreleasepool {
                var handle: FileHandle? = message.fileHandle(key: "fd")!
                defer { handle = nil }
                return handle!.fileDescriptor
            }
            assertDescriptorsAreClosed([descriptor])
        }
    }

    @Test("Setting a file handle does not consume the source descriptor")
    func settingFileHandleDoesNotConsumeSource() throws {
        let source = try #require(FileHandle(forReadingAtPath: "/dev/null"))
        defer { try? source.close() }

        let message = XPCMessage(route: "dial")
        message.set(key: "fd", value: source)

        #expect(isDescriptorOpen(source.fileDescriptor))
    }

    @Test("Setting file handles does not consume the source descriptors")
    func settingFileHandlesDoesNotConsumeSources() throws {
        let sources = [
            try #require(FileHandle(forReadingAtPath: "/dev/null")),
            try #require(FileHandle(forReadingAtPath: "/dev/null")),
        ]
        defer { sources.forEach { try? $0.close() } }

        let message = XPCMessage(route: "logs")
        try message.set(key: "logs", value: sources)

        #expect(sources.allSatisfy { isDescriptorOpen($0.fileDescriptor) })
    }

    private func assertDescriptorsAreClosed(_ descriptors: [Int32]) {
        for descriptor in descriptors {
            let closed = isDescriptorClosed(descriptor)
            #expect(closed)
            if !closed {
                close(descriptor)
            }
        }
    }

    private func isDescriptorOpen(_ descriptor: Int32) -> Bool {
        errno = 0
        return fcntl(descriptor, F_GETFD) != -1
    }

    private func isDescriptorClosed(_ descriptor: Int32) -> Bool {
        errno = 0
        return fcntl(descriptor, F_GETFD) == -1 && errno == EBADF
    }
}
