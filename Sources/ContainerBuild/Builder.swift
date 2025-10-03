//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import ContainerClient
import Containerization
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GRPC
import NIO
import NIOHPACK
import NIOHTTP2

public struct Builder: Sendable {
    let client: BuilderClientProtocol
    let clientAsync: BuilderClientAsyncProtocol
    let group: EventLoopGroup
    let builderShimSocket: FileHandle
    let channel: GRPCChannel

    public init(socket: FileHandle, group: EventLoopGroup) throws {
        try socket.setSendBufSize(4 << 20)
        try socket.setRecvBufSize(2 << 20)
        var config = ClientConnection.Configuration.default(
            target: .connectedSocket(socket.fileDescriptor),
            eventLoopGroup: group
        )
        config.connectionIdleTimeout = TimeAmount(.seconds(600))
        config.connectionKeepalive = .init(
            interval: TimeAmount(.seconds(600)),
            timeout: TimeAmount(.seconds(500)),
            permitWithoutCalls: true
        )
        config.connectionBackoff = .init(
            initialBackoff: TimeInterval(1),
            maximumBackoff: TimeInterval(10)
        )
        config.callStartBehavior = .fastFailure
        config.httpMaxFrameSize = 8 << 10
        config.maximumReceiveMessageLength = 512 << 20
        config.httpTargetWindowSize = 16 << 10

        let channel = ClientConnection(configuration: config)
        self.channel = channel
        self.clientAsync = BuilderClientAsync(channel: channel)
        self.client = BuilderClient(channel: channel)
        self.group = group
        self.builderShimSocket = socket
    }

    public func info() throws -> InfoResponse {
        let resp = self.client.info(InfoRequest(), callOptions: CallOptions())
        return try resp.response.wait()
    }

    public func info() async throws -> InfoResponse {
        let opts = CallOptions(timeLimit: .timeout(.seconds(30)))
        return try await self.clientAsync.info(InfoRequest(), callOptions: opts)
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

        let respStream = self.clientAsync.performBuild(reqStream, callOptions: try CallOptions(config))
        let pipeline = try await BuildPipeline(config)
        do {
            try await pipeline.run(sender: continuation, receiver: respStream)
        } catch Error.buildComplete {
            _ = channel.close()
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
        public let tag: String
        public let target: String
        public let quiet: Bool
        public let exports: [BuildExport]
        public let cacheIn: [String]
        public let cacheOut: [String]

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
            tag: String,
            target: String,
            quiet: Bool,
            exports: [BuildExport],
            cacheIn: [String],
            cacheOut: [String],
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
            self.tag = tag
            self.target = target
            self.quiet = quiet
            self.exports = exports
            self.cacheIn = cacheIn
            self.cacheOut = cacheOut
        }
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

extension CallOptions {
    public init(_ config: Builder.BuildConfig) throws {
        var headers: [(String, String)] = [
            ("build-id", config.buildID),
            ("context", URL(filePath: config.contextDir).path(percentEncoded: false)),
            ("dockerfile", config.dockerfile.base64EncodedString()),
            ("progress", config.terminal != nil ? "tty" : "plain"),
            ("tag", config.tag),
            ("target", config.target),
        ]
        for platform in config.platforms {
            headers.append(("platforms", platform.description))
        }
        if config.noCache {
            headers.append(("no-cache", ""))
        }
        for label in config.labels {
            headers.append(("labels", label))
        }
        for buildArg in config.buildArgs {
            headers.append(("build-args", buildArg))
        }
        for output in config.exports {
            headers.append(("outputs", try output.stringValue))
        }
        for cacheIn in config.cacheIn {
            headers.append(("cache-in", cacheIn))
        }
        for cacheOut in config.cacheOut {
            headers.append(("cache-out", cacheOut))
        }

        self.init(
            customMetadata: HPACKHeaders(headers)
        )
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
