//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import Containerization
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import NIO
import NIOCore
import NIOHPACK
import NIOHTTP2
import NIOPosix

public struct Builder: Sendable {
    public static let builderContainerId = "buildkit"

    let client: Com_Apple_Container_Build_V1_Builder.Client<HTTP2ClientTransport.WrappedChannel>
    let grpcClient: GRPCClient<HTTP2ClientTransport.WrappedChannel>
    let group: EventLoopGroup
    let builderShimSocket: FileHandle
    let clientTask: Task<Void, any Swift.Error>
    let logger: Logger

    public init(socket: FileHandle, group: EventLoopGroup, logger: Logger) throws {
        try socket.setSendBufSize(4 << 20)
        try socket.setRecvBufSize(2 << 20)

        let channel = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture(withResultOf: {
                    try channel.pipeline.syncOperations.addHandler(HTTP2ConnectBufferingHandler())
                })
            }
            .withConnectedSocket(socket.fileDescriptor)
            .wait()

        let transport = HTTP2ClientTransport.WrappedChannel.wrapping(
            channel: channel
        )

        let grpcClient = GRPCClient(transport: transport)
        self.grpcClient = grpcClient
        self.client = Com_Apple_Container_Build_V1_Builder.Client(wrapping: grpcClient)
        self.group = group
        self.builderShimSocket = socket
        self.logger = logger

        // Start the client connection loop in a background task
        self.clientTask = Task {
            do {
                try await grpcClient.runConnections()
            } catch is CancellationError {
                // Expected during graceful shutdown - re-throw
                throw CancellationError()
            } catch let error as RPCError where error.code == .unavailable {
                // Connection closed - this is expected when the container stops
                logger.debug("gRPC connection closed: \(error)")
                throw error
            } catch {
                // Log unexpected connection errors
                logger.error("gRPC client connection error: \(error)")
                throw error
            }
        }
    }

    public func info() async throws -> InfoResponse {
        var opts = CallOptions.defaults
        opts.timeout = .seconds(30)
        return try await self.client.info(InfoRequest(), options: opts)
    }

    // TODO
    // - Symlinks in build context dir
    // - cache-to, cache-from
    // - output (other than the default OCI image output, e.g., local, tar, Docker)
    public func build(_ config: BuildConfig) async throws {
        var continuation: AsyncStream<ClientStream>.Continuation?
        let reqStream = AsyncStream<ClientStream> { (cont: AsyncStream<ClientStream>.Continuation) in
            continuation = cont
        }
        guard let continuation else {
            throw Error.invalidContinuation
        }

        defer {
            continuation.finish()
        }

        if let terminal = config.terminal {
            Task {
                let winchHandler = AsyncSignalHandler.create(notify: [SIGWINCH])
                let setWinch = { (rows: UInt16, cols: UInt16) in
                    var winch = ClientStream()
                    winch.command = .init()
                    if let cmdString = try TerminalCommand(rows: rows, cols: cols).json() {
                        winch.command.command = cmdString
                        continuation.yield(winch)
                    }
                }
                let size = try terminal.size
                var width = size.width
                var height = size.height
                try setWinch(height, width)

                for await _ in winchHandler.signals {
                    let size = try terminal.size
                    let cols = size.width
                    let rows = size.height
                    if cols != width || rows != height {
                        width = cols
                        height = rows
                        try setWinch(height, width)
                    }
                }
            }
        }

        let pipeline = try await BuildPipeline(config)
        do {
            try await self.client.performBuild(
                metadata: try Self.buildMetadata(config),
                options: .defaults,
                requestProducer: { writer in
                    for await message in reqStream {
                        try await writer.write(message)
                    }
                },
                onResponse: { response in
                    try await pipeline.run(sender: continuation, receiver: response.messages)
                }
            )
        } catch Error.buildComplete {
            self.grpcClient.beginGracefulShutdown()
            self.clientTask.cancel()
            try await group.shutdownGracefully()
            return
        }
    }

    public struct BuildExport: Sendable {
        public let type: String
        public var destination: URL?
        public let additionalFields: [String: String]
        public let rawValue: String

        public init(type: String, destination: URL?, additionalFields: [String: String], rawValue: String) {
            self.type = type
            self.destination = destination
            self.additionalFields = additionalFields
            self.rawValue = rawValue
        }

        public init(from input: String) throws {
            var typeValue: String?
            var destinationValue: URL?
            var additionalFields: [String: String] = [:]

            let pairs = input.components(separatedBy: ",")
            for pair in pairs {
                let parts = pair.components(separatedBy: "=")
                guard parts.count == 2 else { continue }

                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)

                switch key {
                case "type":
                    typeValue = value
                case "dest":
                    destinationValue = try Self.resolveDestination(dest: value)
                default:
                    additionalFields[key] = value
                }
            }

            guard let type = typeValue else {
                throw Builder.Error.invalidExport(input, "type field is required")
            }

            switch type {
            case "oci":
                break
            case "tar":
                if destinationValue == nil {
                    throw Builder.Error.invalidExport(input, "dest field is required")
                }
            case "local":
                if destinationValue == nil {
                    throw Builder.Error.invalidExport(input, "dest field is required")
                }
            default:
                throw Builder.Error.invalidExport(input, "unsupported output type")
            }

            self.init(type: type, destination: destinationValue, additionalFields: additionalFields, rawValue: input)
        }

        public var stringValue: String {
            get throws {
                var components = ["type=\(type)"]

                switch type {
                case "oci", "tar", "local":
                    break  // ignore destination
                default:
                    throw Builder.Error.invalidExport(rawValue, "unsupported output type")
                }

                for (key, value) in additionalFields {
                    components.append("\(key)=\(value)")
                }

                return components.joined(separator: ",")
            }
        }

        static func resolveDestination(dest: String) throws -> URL {
            let destination = URL(fileURLWithPath: dest)
            let fileManager = FileManager.default

            if fileManager.fileExists(atPath: destination.path) {
                let resourceValues = try destination.resourceValues(forKeys: [.isDirectoryKey])
                let isDir = resourceValues.isDirectory
                if isDir != nil && isDir == false {
                    throw Builder.Error.invalidExport(dest, "dest path already exists")
                }

                var finalDestination = destination.appendingPathComponent("out.tar")
                var index = 1
                while fileManager.fileExists(atPath: finalDestination.path) {
                    let path = "out.tar.\(index)"
                    finalDestination = destination.appendingPathComponent(path)
                    index += 1
                }
                return finalDestination
            } else {
                let parentDirectory = destination.deletingLastPathComponent()
                try? fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true, attributes: nil)
            }

            return destination
        }
    }

    public struct BuildConfig: Sendable {
        public let buildID: String
        public let contentStore: ContentStore
        public let buildArgs: [String]
        public let contextDir: String
        public let dockerfile: Data
        public let labels: [String]
        public let noCache: Bool
        public let platforms: [Platform]
        public let terminal: Terminal?
        public let tags: [String]
        public let target: String
        public let quiet: Bool
        public let exports: [BuildExport]
        public let cacheIn: [String]
        public let cacheOut: [String]
        public let pull: Bool

        public init(
            buildID: String,
            contentStore: ContentStore,
            buildArgs: [String],
            contextDir: String,
            dockerfile: Data,
            labels: [String],
            noCache: Bool,
            platforms: [Platform],
            terminal: Terminal?,
            tags: [String],
            target: String,
            quiet: Bool,
            exports: [BuildExport],
            cacheIn: [String],
            cacheOut: [String],
            pull: Bool
        ) {
            self.buildID = buildID
            self.contentStore = contentStore
            self.buildArgs = buildArgs
            self.contextDir = contextDir
            self.dockerfile = dockerfile
            self.labels = labels
            self.noCache = noCache
            self.platforms = platforms
            self.terminal = terminal
            self.tags = tags
            self.target = target
            self.quiet = quiet
            self.exports = exports
            self.cacheIn = cacheIn
            self.cacheOut = cacheOut
            self.pull = pull
        }
    }

    static func buildMetadata(_ config: BuildConfig) throws -> Metadata {
        var metadata = Metadata()
        metadata.addString(config.buildID, forKey: "build-id")
        metadata.addString(URL(filePath: config.contextDir).path(percentEncoded: false), forKey: "context")
        metadata.addString(config.dockerfile.base64EncodedString(), forKey: "dockerfile")
        metadata.addString(config.terminal != nil ? "tty" : "plain", forKey: "progress")
        metadata.addString(config.target, forKey: "target")

        for tag in config.tags {
            metadata.addString(tag, forKey: "tag")
        }
        for platform in config.platforms {
            metadata.addString(platform.description, forKey: "platforms")
        }
        if config.noCache {
            metadata.addString("", forKey: "no-cache")
        }
        for label in config.labels {
            metadata.addString(label, forKey: "labels")
        }
        for buildArg in config.buildArgs {
            metadata.addString(buildArg, forKey: "build-args")
        }
        for output in config.exports {
            metadata.addString(try output.stringValue, forKey: "outputs")
        }
        for cacheIn in config.cacheIn {
            metadata.addString(cacheIn, forKey: "cache-in")
        }
        for cacheOut in config.cacheOut {
            metadata.addString(cacheOut, forKey: "cache-out")
        }

        return metadata
    }
}

extension Builder {
    enum Error: Swift.Error, CustomStringConvertible {
        case invalidContinuation
        case buildComplete
        case invalidExport(String, String)

        var description: String {
            switch self {
            case .invalidContinuation:
                return "continuation could not created"
            case .buildComplete:
                return "build completed"
            case .invalidExport(let exp, let reason):
                return "export entry \(exp) is invalid: \(reason)"
            }
        }
    }
}

extension FileHandle {
    @discardableResult
    func setSendBufSize(_ bytes: Int) throws -> Int {
        try setSockOpt(
            level: SOL_SOCKET,
            name: SO_SNDBUF,
            value: bytes)
        return bytes
    }

    @discardableResult
    func setRecvBufSize(_ bytes: Int) throws -> Int {
        try setSockOpt(
            level: SOL_SOCKET,
            name: SO_RCVBUF,
            value: bytes)
        return bytes
    }

    private func setSockOpt(level: Int32, name: Int32, value: Int) throws {
        var v = Int32(value)
        let res = withUnsafePointer(to: &v) { ptr -> Int32 in
            ptr.withMemoryRebound(
                to: UInt8.self,
                capacity: MemoryLayout<Int32>.size
            ) { raw in
                #if canImport(Darwin)
                return setsockopt(
                    self.fileDescriptor,
                    level, name,
                    raw,
                    socklen_t(MemoryLayout<Int32>.size))
                #else
                fatalError("unsupported platform")
                #endif
            }
        }
        if res == -1 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
    }
}

/// Buffers incoming bytes until the full gRPC HTTP/2 pipeline is configured, then replays them.
///
/// See the equivalent in Containerization/Vminitd.swift for a full explanation.
private final class HTTP2ConnectBufferingHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var removalScheduled = false
    private var bufferedReads: [NIOAny] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bufferedReads.append(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {}

    func flush(context: ChannelHandlerContext) {
        if !removalScheduled {
            removalScheduled = true
            context.eventLoop.assumeIsolatedUnsafeUnchecked().execute {
                context.pipeline.syncOperations.removeHandler(self, promise: nil)
            }
        }
        context.flush()
    }

    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        var didRead = false
        while !bufferedReads.isEmpty {
            context.fireChannelRead(bufferedReads.removeFirst())
            didRead = true
        }
        if didRead {
            context.fireChannelReadComplete()
        }
        context.leavePipeline(removalToken: removalToken)
    }

    func channelInactive(context: ChannelHandlerContext) {
        bufferedReads.removeAll()
        context.fireChannelInactive()
    }
}
