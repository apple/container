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
import ContainerizationOCI
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

/// Where cluster-shim finds and serves its sockets.
public struct ShimPaths: Sendable {
    /// The host content store, relayed into the node.
    public var hostSocket: String
    /// The kubelet's imageServiceEndpoint.
    public var imageSocket: String
    /// containerd's API and CRI services.
    public var containerdSocket: String

    public init(hostSocket: String, imageSocket: String, containerdSocket: String) {
        self.hostSocket = hostSocket
        self.imageSocket = imageSocket
        self.containerdSocket = containerdSocket
    }
}

/// The rate of PING and other control frames cluster-shim accepts from
/// containerd and the kubelet. grpc-go sends a PING for most DATA frames it
/// receives, far more than the default limit allows while a blob is copied.
let controlFrameLimit = RateLimit(maxCount: 65535, window: .seconds(1))

/// Serves the kubelet's CRI image service on a root-only Unix socket until the
/// server stops.
public func runClusterShim(paths: ShimPaths, log: Logger) async throws {
    // Fail at once when the host store is unreachable, so requests fall
    // through to containerd instead of waiting out connection retries.
    var httpConfig = HTTPClient.Configuration()
    httpConfig.connectionPool.retryConnectionEstablishment = false
    // Shorter than the host store server's 60 second idle timeout, so the
    // client drops an idle connection before the server closes it.
    httpConfig.connectionPool.idleTimeout = .seconds(30)
    // Fails a blob whose body stops arriving, however large the blob is.
    httpConfig.timeout.read = .seconds(60)
    let host = HTTPHostStore(socketPath: paths.hostSocket, client: HTTPClient(configuration: httpConfig))

    var clientConfig = HTTP2ClientTransport.Posix.Config.defaults
    clientConfig.http2.authority = "localhost"
    clientConfig.http2.rateLimits.controlFrames = controlFrameLimit
    let containerd = GRPCClient(
        transport: try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: paths.containerdSocket),
            transportSecurity: .plaintext,
            config: clientConfig
        )
    )
    let recorder = HostImageRecorder(
        host: host,
        content: ContentAPI.Client(wrapping: containerd),
        images: ImagesAPI.Client(wrapping: containerd),
        leases: LeasesAPI.Client(wrapping: containerd),
        platform: .current
    )

    let imageTransport = try serverTransport(socketPath: paths.imageSocket)
    let imageServer = GRPCServer(
        transport: imageTransport,
        services: [
            ImageService(
                containerd: CRIImageAPI.Client(wrapping: containerd),
                host: host,
                recordHostImage: { name, target in try await recorder.record(name: name, target: target) },
                log: log
            )
        ]
    )

    try await withThrowingDiscardingTaskGroup { group in
        group.addTask { try await containerd.runConnections() }
        group.addTask { try await imageServer.serve() }

        _ = try await imageTransport.listeningAddress
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.imageSocket)
        log.info("serving", metadata: ["images": "\(paths.imageSocket)"])
    }
}

/// A plaintext gRPC transport on a Unix socket, replacing a stale socket file.
private func serverTransport(socketPath: String) throws -> HTTP2ServerTransport.Posix {
    let fileManager = FileManager.default
    let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if fileManager.fileExists(atPath: socketPath) {
        try fileManager.removeItem(atPath: socketPath)
    }
    var config = HTTP2ServerTransport.Posix.Config.defaults
    config.http2.rateLimits.controlFrames = controlFrameLimit
    return HTTP2ServerTransport.Posix(address: .unixDomainSocket(path: socketPath), transportSecurity: .plaintext, config: config)
}
