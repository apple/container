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

@testable import ContainerXPC

@Suite("XPC client lifecycle")
struct XPCClientTests {
    @Test(.timeLimit(.minutes(1)))
    func cancelledReplyWaitDoesNotWaitForCallback() async {
        let task = Task {
            try await XPCClient.waitForReply(service: "test", route: "never") { _ in }
        }
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func replyTimeoutDoesNotWaitForCallback() async {
        await #expect(throws: ContainerizationError.self) {
            try await XPCClient.waitForReply(
                responseTimeout: .milliseconds(10),
                service: "test",
                route: "never"
            ) { _ in }
        }
    }

    @Test
    func transferringFileHandleClosesItsOwnerExactlyOnce() throws {
        let (handle, descriptor) = ownedHandle(minimumDescriptor: 500)
        let message = XPCMessage(route: "test")

        try message.setFileHandle(key: "fd", value: handle)
        installReplacement(at: descriptor)
        defer { Darwin.close(descriptor) }

        try? handle.close()
        #expect(Darwin.fcntl(descriptor, F_GETFD) >= 0)
    }

    @Test
    func transferringFileHandleArrayClosesOwnersExactlyOnce() throws {
        let (first, firstDescriptor) = ownedHandle(minimumDescriptor: 500)
        let (second, _) = ownedHandle(minimumDescriptor: 501)
        let message = XPCMessage(route: "test")

        try message.set(key: "fds", value: [first, second])
        installReplacement(at: firstDescriptor)
        defer { Darwin.close(firstDescriptor) }

        try? first.close()
        try? second.close()
        #expect(Darwin.fcntl(firstDescriptor, F_GETFD) >= 0)
    }

    private func ownedHandle(minimumDescriptor: Int32) -> (FileHandle, Int32) {
        let source = Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
        #expect(source >= 0)
        defer { Darwin.close(source) }
        let descriptor = Darwin.fcntl(source, F_DUPFD_CLOEXEC, minimumDescriptor)
        #expect(descriptor >= minimumDescriptor)
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), descriptor)
    }

    private func installReplacement(at descriptor: Int32) {
        let source = Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
        #expect(source >= 0)
        defer { Darwin.close(source) }
        #expect(Darwin.dup2(source, descriptor) == descriptor)
    }
}
