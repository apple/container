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

/// Where cluster-shim finds and serves its sockets and stores.
public struct ShimPaths: Sendable {
    /// The host content store, relayed into the node.
    public var hostSocket: String
    /// Where containerd's proxy content plugin connects.
    public var contentSocket: String
    /// The kubelet's imageServiceEndpoint.
    public var imageSocket: String
    /// containerd's API and CRI services.
    public var containerdSocket: String
    /// containerd's local content store directory.
    public var contentRoot: String

    public init(hostSocket: String, contentSocket: String, imageSocket: String, containerdSocket: String, contentRoot: String) {
        self.hostSocket = hostSocket
        self.contentSocket = contentSocket
        self.imageSocket = imageSocket
        self.containerdSocket = containerdSocket
        self.contentRoot = contentRoot
    }
}

/// Serves containerd's content store and the kubelet's CRI image service on
/// root-only Unix sockets until one of the servers stops.
public func runClusterShim(paths: ShimPaths, log: Logger) async throws {
    let local = try LocalStore(root: URL(fileURLWithPath: paths.contentRoot))
    // Fail at once when the host store is unreachable, so requests fall
    // through to containerd instead of waiting out connection retries.
    var httpConfig = HTTPClient.Configuration()
    httpConfig.connectionPool.retryConnectionEstablishment = false
    let host = HTTPHostStore(socketPath: paths.hostSocket, client: HTTPClient(configuration: httpConfig))

    var clientConfig = HTTP2ClientTransport.Posix.Config.defaults
    clientConfig.http2.authority = "localhost"
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

    let contentTransport = try serverTransport(socketPath: paths.contentSocket)
    let contentServer = GRPCServer(
        transport: contentTransport,
        services: [ContentService(store: TieredStore(local: local, host: host))]
    )
    let imageTransport = try serverTransport(socketPath: paths.imageSocket)
    let imageServer = GRPCServer(
        transport: imageTransport,
        services: [
            ImageService(
                containerd: CRIImageAPI.Client(wrapping: containerd),
                host: host,
                recordHostImage: { reference in try await recorder.record(reference: reference) },
                log: log
            )
        ]
    )

    try await withThrowingDiscardingTaskGroup { group in
        group.addTask { try await containerd.runConnections() }
        group.addTask { try await contentServer.serve() }
        group.addTask { try await imageServer.serve() }

        _ = try await contentTransport.listeningAddress
        _ = try await imageTransport.listeningAddress
        try restrictToOwner(socketPath: paths.contentSocket)
        try restrictToOwner(socketPath: paths.imageSocket)
        log.info("serving", metadata: ["content": "\(paths.contentSocket)", "images": "\(paths.imageSocket)"])
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
    config.rpc.maxRequestPayloadSize = 16 << 20
    return HTTP2ServerTransport.Posix(address: .unixDomainSocket(path: socketPath), transportSecurity: .plaintext, config: config)
}

private func restrictToOwner(socketPath: String) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socketPath)
}
