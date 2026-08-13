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
import ContainerizationOS
import Darwin
import Foundation

extension Application.BuildCommand {
    /// Where a build's builder lives when it is not this machine's.
    ///
    /// The address grammar is BUILDKIT_HOST's: an ssh address reaches a peer
    /// whose sshd and container CLI are the whole of the requirement, the
    /// ssh channel carrying the authentication and encryption, and a tcp
    /// address reaches a listener directly.
    /// https://github.com/moby/buildkit/blob/master/client/connhelper/ssh/ssh.go
    enum RemoteBuilderAddress {
        case ssh(user: String?, host: String, port: Int?)
        case tcp(host: String, port: Int)

        static func parse(_ address: String) throws -> RemoteBuilderAddress {
            guard let url = URL(string: address), let scheme = url.scheme, let host = url.host else {
                throw ContainerizationError(.invalidArgument, message: "invalid builder address \(address)")
            }
            switch scheme {
            case "ssh":
                return .ssh(user: url.user, host: host, port: url.port)
            case "tcp":
                guard let port = url.port else {
                    throw ContainerizationError(.invalidArgument, message: "a tcp builder address names a port: \(address)")
                }
                return .tcp(host: host, port: port)
            default:
                throw ContainerizationError(.invalidArgument, message: "unsupported builder address scheme \(scheme); use ssh:// or tcp://")
            }
        }
    }

    /// A connection to a remote builder, held open for the build riding it.
    ///
    /// For ssh the connection is the standard streams of an ssh child
    /// running the peer's `container builder dial-stdio`, one socketpair end
    /// serving as both of the child's streams so the handle speaks both
    /// ways, the way buildkit's connection helpers wrap a command's stdio.
    /// The child lives as long as this value does.
    struct RemoteBuilderConnection {
        let handle: FileHandle
        private let process: Command?

        static func connect(_ address: RemoteBuilderAddress) throws -> RemoteBuilderConnection {
            switch address {
            case .ssh(let user, let host, let port):
                var fds: [Int32] = [0, 0]
                guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                    throw ContainerizationError(.internalError, message: "socketpair failed: errno \(errno)")
                }
                let parent = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
                let child = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)

                var arguments = ["-T", "-o", "BatchMode=yes"]
                if let port {
                    arguments += ["-p", "\(port)"]
                }
                let destination = user.map { "\($0)@\(host)" } ?? host
                arguments += ["--", destination, "container", "builder", "dial-stdio"]

                var command = Command("/usr/bin/ssh", arguments: arguments)
                command.stdin = child
                command.stdout = child
                do {
                    try command.start()
                } catch {
                    try? parent.close()
                    try? child.close()
                    throw ContainerizationError(.internalError, message: "failed to start ssh to \(destination)", cause: error)
                }
                try? child.close()
                return RemoteBuilderConnection(handle: parent, process: command)

            case .tcp(let host, let port):
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var info: UnsafeMutablePointer<addrinfo>?
                let rc = getaddrinfo(host, "\(port)", &hints, &info)
                guard rc == 0, let first = info else {
                    throw ContainerizationError(.internalError, message: "failed to resolve \(host): \(String(cString: gai_strerror(rc)))")
                }
                defer { freeaddrinfo(info) }

                var lastErrno: Int32 = 0
                var candidate = Optional(first)
                while let ai = candidate {
                    let fd = Darwin.socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
                    if fd >= 0 {
                        if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                            return RemoteBuilderConnection(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: false), process: nil)
                        }
                        lastErrno = errno
                        Darwin.close(fd)
                    } else {
                        lastErrno = errno
                    }
                    candidate = ai.pointee.ai_next
                }
                throw ContainerizationError(.internalError, message: "failed to connect to \(host):\(port): errno \(lastErrno)")
            }
        }
    }
}
