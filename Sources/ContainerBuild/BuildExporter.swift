//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import ContainerizationArchive
import Foundation
import GRPC
import NIO

actor BuildExporter: BuildPipelineHandler {
    let output: OutputStream
    let channel: AsyncThrowingStream<(AsyncStream<ClientStream>.Continuation, ServerStream), Swift.Error>.Continuation

    public init(output: URL) throws {
        guard let output = OutputStream(toFileAtPath: output.absolutePath(), append: true) else {
            throw Error.couldNotInitializeOutput(output.absolutePath())
        }
        self.output = output
        self.output.open()
        var c: AsyncThrowingStream<(AsyncStream<ClientStream>.Continuation, ServerStream), Swift.Error>.Continuation?
        let writeStream: AsyncThrowingStream<(AsyncStream<ClientStream>.Continuation, ServerStream), Swift.Error> = AsyncThrowingStream { continuation in
            c = continuation
        }
        guard let c else {
            throw Builder.Error.invalidContinuation
        }
        self.channel = c
        Task.detached {
            for try await packet in writeStream {
                try await self.write(packet.0, packet.1)
            }
        }
    }

    nonisolated func accept(_ packet: ServerStream) throws -> Bool {
        guard let buildTransfer = packet.getBuildTransfer() else {
            return false
        }
        guard buildTransfer.stage() == "exporter" else {
            return false
        }
        return true
    }

    func handle(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ServerStream) async throws {
        self.channel.yield((sender, packet)) // guarantees ordering while being non-blocking
    }

    func write(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ServerStream) async throws {
        guard let buildTransfer = packet.getBuildTransfer() else {
            throw Error.buildTransferMissing
        }
        guard buildTransfer.stage() == "exporter" else {
            throw Error.invalidStage(buildTransfer.stage() ?? "")
        }
        let buildID = packet.buildID
        if buildTransfer.complete {
            var transfer = BuildTransfer()
            transfer.id = buildTransfer.id
            transfer.direction = .outof
            transfer.metadata = [
                "os": "linux",
                "stage": "exporter",
            ]
            var response = ClientStream()
            response.buildID = buildID
            response.buildTransfer = transfer
            response.packetType = .buildTransfer(transfer)
            sender.yield(response)
            
            self.output.close()
            return
        }
        try buildTransfer.data.withUnsafeBytes { rawBuf in
            let bufPointer = rawBuf.bindMemory(to: UInt8.self)
            if let baseAddr = bufPointer.baseAddress, bufPointer.count > 0 {
                let n = self.output.write(baseAddr, maxLength: bufPointer.count)
                if n < 0 || n < bufPointer.count {
                    throw Error.writeError
                }
            }
        }
        var transfer = BuildTransfer()
        transfer.id = buildTransfer.id
        transfer.direction = .outof
        transfer.metadata = [
            "os": "linux",
            "stage": "exporter",
        ]
        var response = ClientStream()
        response.buildID = buildID
        response.buildTransfer = transfer
        response.packetType = .buildTransfer(transfer)
        sender.yield(response)
    }
}

extension BuildExporter {
    enum Error: Swift.Error, CustomStringConvertible {
        case buildTransferMissing
        case invalidStage(String)
        case couldNotInitializeOutput(String)
        case writeError
        var description: String {
            switch self {
            case .buildTransferMissing:
                return "buildTransfer field missing in packet"
            case .invalidStage(let stage):
                return "stage \(stage) is invalid, expected 'exporter'"
            case .couldNotInitializeOutput(let output):
                return "could not open \(output) for writing"
            case .writeError:
                return "write failed"
            }
        }
    }
}
