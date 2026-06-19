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

import ArgumentParser
import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Darwin
import Dispatch
import Foundation

extension Application {
    public struct ContainerLogs: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "logs",
            abstract: "Fetch container logs"
        )

        @Flag(name: .long, help: "Display the boot log for the container instead of stdio")
        var boot: Bool = false

        @Flag(name: .shortAndLong, help: "Follow log output")
        var follow: Bool = false

        @Option(name: [.short, .customLong("tail")], help: "Number of lines to show from the end of the logs. If not provided this will print all of the logs")
        var numLines: Int?

        @Option(name: .long, help: "Show logs after the specified RFC 3339 timestamp")
        var since: ContainerLogTimestamp?

        @Option(name: .long, help: "Show logs before the specified RFC 3339 timestamp")
        var until: ContainerLogTimestamp?

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container ID")
        var containerId: String

        public func validate() throws {
            try Self.validateLogOptions(follow: follow, since: since, until: until)
        }

        public func run() async throws {
            let client = ContainerClient()
            let options = Self.retrievalOptions(
                numLines: numLines,
                follow: follow,
                since: since,
                until: until
            )
            let fhs = try await client.logs(id: containerId, options: options)
            let fileHandle = boot ? fhs[1] : fhs[0]

            try await Self.tail(
                fh: fileHandle,
                n: follow ? numLines : nil,
                follow: follow
            )
        }

        static func validateLogOptions(
            follow: Bool,
            since: ContainerLogTimestamp?,
            until: ContainerLogTimestamp?
        ) throws {
            if follow && (since != nil || until != nil) {
                throw ValidationError("--follow cannot be combined with --since or --until")
            }
        }

        static func retrievalOptions(
            numLines: Int?,
            follow: Bool,
            since: ContainerLogTimestamp?,
            until: ContainerLogTimestamp?
        ) -> ContainerLogOptions {
            ContainerLogOptions(
                tail: follow ? nil : numLines,
                since: since?.date,
                until: until?.date
            )
        }

        private static func tail(
            fh: FileHandle,
            n: Int?,
            follow: Bool
        ) async throws {
            if let n {
                var buffer = Data()
                let size = try fh.seekToEnd()
                var offset = size
                var lines: [String] = []

                while offset > 0, lines.count < n {
                    let readSize = min(1024, offset)
                    offset -= readSize
                    try fh.seek(toOffset: offset)

                    let data = fh.readData(ofLength: Int(readSize))
                    buffer.insert(contentsOf: data, at: 0)

                    if let chunk = String(data: buffer, encoding: .utf8) {
                        lines = chunk.components(separatedBy: .newlines)
                        lines = lines.filter { !$0.isEmpty }
                    }
                }

                lines = Array(lines.suffix(n))
                for line in lines {
                    print(line)
                }
            } else {
                // Fast path if all they want is the full file.
                guard let data = try fh.readToEnd() else {
                    // Seems you get nil if it's a zero byte read, or you
                    // try and read from dev/null.
                    return
                }
                guard let str = String(data: data, encoding: .utf8) else {
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to convert container logs to utf8"
                    )
                }
                print(str.trimmingCharacters(in: .newlines))
            }

            fflush(stdout)
            if follow {
                setbuf(stdout, nil)
                try await Self.followFile(fh: fh)
            }
        }

        private static func followFile(fh: FileHandle) async throws {
            _ = try fh.seekToEnd()
            let stream = AsyncStream<String> { cont in
                fh.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        // Triggers on container restart - can exit here as well
                        do {
                            _ = try fh.seekToEnd()  // To continue streaming existing truncated log files
                        } catch {
                            fh.readabilityHandler = nil
                            cont.finish()
                            return
                        }
                    }
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        var lines = str.components(separatedBy: .newlines)
                        lines = lines.filter { !$0.isEmpty }
                        for line in lines {
                            cont.yield(line)
                        }
                    }
                }
            }

            for await line in stream {
                print(line)
            }
        }
    }
}

struct ContainerLogTimestamp: ExpressibleByArgument, Equatable {
    let date: Date

    init?(argument: String) {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        if let date = fractionalFormatter.date(from: argument) ?? formatter.date(from: argument) {
            self.date = date
            return
        }
        return nil
    }
}
