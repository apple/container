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

import Foundation
import Logging
import NIOCore
import NIOPosix

/// Handler that forwards DNS queries to upstream DNS servers.
public struct ForwardingResolver: DNSHandler {
    public struct Upstream: Sendable, Equatable {
        public let host: String
        public let port: Int

        public init(host: String, port: Int = 53) {
            self.host = host
            self.port = port
        }
    }

    private let upstreams: [Upstream]
    private let timeoutNanoseconds: UInt64
    private let log: Logger?

    public init(
        upstreams: [Upstream],
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        log: Logger? = nil
    ) {
        self.upstreams = upstreams
        self.timeoutNanoseconds = timeoutNanoseconds
        self.log = log
    }

    public func answer(query: Message) async throws -> Message? {
        for upstream in upstreams {
            do {
                if let response = try await forward(query: query, to: upstream) {
                    return response
                }
            } catch {
                log?.debug(
                    "DNS upstream query failed",
                    metadata: [
                        "host": "\(upstream.host)",
                        "port": "\(upstream.port)",
                        "error": "\(error)",
                    ])
            }
        }
        return nil
    }

    public static func systemUpstreams(resolvConfPath: String = "/etc/resolv.conf") -> [Upstream] {
        guard let contents = try? String(contentsOfFile: resolvConfPath, encoding: .utf8) else {
            return [Upstream(host: "1.1.1.1")]
        }

        let upstreams = contents
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Upstream? in
                let stripped = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                let parts = stripped.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2, parts[0] == "nameserver" else {
                    return nil
                }
                let host = String(parts[1])
                guard isUsableUpstreamHost(host) else {
                    return nil
                }
                return Upstream(host: host)
            }

        return upstreams.isEmpty ? [Upstream(host: "1.1.1.1")] : upstreams
    }

    private static func isUsableUpstreamHost(_ host: String) -> Bool {
        guard !host.hasPrefix("127."), host != "::1", host != "0.0.0.0", host != "::" else {
            return false
        }
        return (try? SocketAddress(ipAddress: host, port: 53)) != nil
    }

    private func forward(query: Message, to upstream: Upstream) async throws -> Message? {
        let queryData = try query.serialize()
        let upstreamAddress = try SocketAddress(ipAddress: upstream.host, port: upstream.port)
        let bindHost = upstream.host.contains(":") ? "::" : "0.0.0.0"
        let channel = try await DatagramBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .bind(host: bindHost, port: 0)
            .flatMapThrowing { channel in
                try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: NIOAsyncChannel.Configuration(
                        inboundType: AddressedEnvelope<ByteBuffer>.self,
                        outboundType: AddressedEnvelope<ByteBuffer>.self
                    )
                )
            }
            .get()

        return try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(AddressedEnvelope(remoteAddress: upstreamAddress, data: ByteBuffer(bytes: queryData)))
            let timeoutNanoseconds = self.timeoutNanoseconds

            return try await withThrowingTaskGroup(of: Message?.self) { group in
                group.addTask {
                    for try await var packet in inbound {
                        var data = Data()
                        while packet.data.readableBytes > 0 {
                            if let chunk = packet.data.readBytes(length: packet.data.readableBytes) {
                                data.append(contentsOf: chunk)
                            }
                        }
                        return try Message(deserialize: data)
                    }
                    return nil
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return nil
                }

                let result = try await group.next() ?? nil
                group.cancelAll()
                return result
            }
        }
    }
}
