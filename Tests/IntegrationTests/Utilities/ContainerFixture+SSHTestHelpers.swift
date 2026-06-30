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

// MARK: - Fake SSH agent socket

extension ContainerFixture {

    /// Creates a Unix-domain listening socket at a short path under `/tmp`,
    /// suitable for use as `SSH_AUTH_SOCK` in tests that exercise `--ssh` forwarding.
    ///
    /// The path is `/tmp/{testID}-ssh/ssh-auth.sock`, which fits comfortably within
    /// `sockaddr_un.sun_path`'s 104-byte limit on macOS regardless of project depth.
    ///
    /// An accept loop runs on a background thread, closing each incoming connection.
    /// `accept()` is a blocking syscall, so `Thread` is appropriate here — using
    /// `Task.detached` would block a cooperative thread without yielding.
    ///
    /// The socket fd and its parent directory are auto-cleaned on fixture scope exit;
    /// closing the listening fd is what causes the accept loop to exit.
    ///
    /// Returns the socket path. Pass it as `SSH_AUTH_SOCK` in the CLI process env.
    func makeFakeSSHAgentSocket() throws -> String {
        let socketDir = "/tmp/\(testID)-ssh"
        try FileManager.default.createDirectory(
            atPath: socketDir, withIntermediateDirectories: true, attributes: nil)
        let socketPath = socketDir + "/ssh-auth.sock"

        let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw CommandError.executionFailed("socket() failed with errno \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { bytes in
            socketPath.withCString { cStr in
                bytes.copyMemory(
                    from: UnsafeRawBufferPointer(start: cStr, count: socketPath.utf8.count + 1))
            }
        }
        let bindResult = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let savedErrno = errno
            Darwin.close(serverFd)
            throw CommandError.executionFailed("bind() failed with errno \(savedErrno) for path \(socketPath)")
        }
        guard listen(serverFd, 5) == 0 else {
            let savedErrno = errno
            Darwin.close(serverFd)
            throw CommandError.executionFailed("listen() failed with errno \(savedErrno)")
        }

        let acceptThread = Thread {
            while true {
                let clientFd = accept(serverFd, nil, nil)
                if clientFd < 0 { break }
                Darwin.close(clientFd)
            }
        }
        acceptThread.start()

        addCleanup {
            Darwin.close(serverFd)
            try? FileManager.default.removeItem(atPath: socketDir)
        }

        return socketPath
    }
}
