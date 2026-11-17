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

import ArgumentParser
import ContainerAPIClient
import NIOCore
import NIOPosix
import SocketForwarder

extension Application {
    public struct SystemSocketForward: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "socket-forward",
            abstract: "Forward a host TCP port to a Unix socket",
            discussion: """
                Runs in the foreground. Combine with `container run --publish-socket`
                for a TCP service that supports Unix sockets. The published Unix socket
                uses the VM relay, so this path does not need the container's IP address.
                This forwards TCP streams only; it does not change container egress or DNS.
                """
        )

        @Option(help: "Numeric IP address for the host listener (default: localhost only)")
        var host: String = "127.0.0.1"

        @Option(help: "TCP port for the host listener (1–65535)")
        var port: Int

        @Option(name: .customLong("socket"), help: "Absolute path to the backend Unix socket on the host")
        var socketPath: String

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func validate() throws {
            guard (1...65535).contains(port) else {
                throw ValidationError("port must be between 1 and 65535")
            }
            guard socketPath.hasPrefix("/") else {
                throw ValidationError("socket must be an absolute host path")
            }
            _ = try SocketAddress(ipAddress: host, port: port)
            _ = try SocketAddress(unixDomainSocketPath: socketPath)
        }

        public func run() async throws {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            do {
                let forwarder = try TCPForwarder(
                    proxyAddress: SocketAddress(ipAddress: host, port: port),
                    serverAddress: SocketAddress(unixDomainSocketPath: socketPath),
                    eventLoopGroup: group,
                    allowRemoteHalfClosure: true,
                    log: log
                )
                let result = try await forwarder.run().get()
                log.info("Forwarding TCP \(host):\(port) to \(socketPath). Press Control-C to stop.")
                try await result.wait()
            } catch {
                try await group.shutdownGracefully()
                throw error
            }
            try await group.shutdownGracefully()
        }
    }
}
