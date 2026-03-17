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

import ContainerizationOS
import Foundation
import GRPC
import NIO

actor BuildStdio: BuildPipelineHandler {
    public let quiet: Bool
    public let handle: FileHandle

    init(quiet: Bool = false, output: FileHandle = FileHandle.standardError) throws {
        self.quiet = quiet
        self.handle = output
    }

    nonisolated func accept(_ packet: ServerStream) throws -> Bool {
        guard let _ = packet.getIO() else {
            return false
        }
        return true
    }

    func handle(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ServerStream) async throws {
        guard !quiet else {
            return
        }
        guard let io = packet.getIO() else {
            throw Error.ioMissing
        }
        if let cmdString = try TerminalCommand().json() {
            var response = ClientStream()
            response.buildID = packet.buildID
            response.command = .init()
            response.command.id = packet.buildID
            response.command.command = cmdString
            sender.yield(response)
        }
        handle.write(io.data)
    }
}

extension BuildStdio {
    enum Error: Swift.Error, CustomStringConvertible {
        case ioMissing
        case invalidContinuation
        var description: String {
            switch self {
            case .ioMissing:
                return "io field missing in packet"
            case .invalidContinuation:
                return "continuation could not created"
            }
        }
    }
}
