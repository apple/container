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
import ContainerizationError
import Foundation

extension Application {
    /// The verb follows docker and nerdctl `builder prune`; the cache walk
    /// itself is buildkit's own `buildctl prune`, run inside the builder.
    /// https://docs.docker.com/reference/cli/docker/builder/prune/
    public struct BuilderPrune: AsyncLoggableCommand {
        public static var configuration: CommandConfiguration {
            var config = CommandConfiguration()
            config.commandName = "prune"
            config.abstract = "Reclaim build cache space and return it to the host"
            return config
        }

        @Option(name: .long, help: "Amount of build cache to keep, with optional K, M, G, or T suffix")
        var keepStorage: String?

        @Flag(name: .long, help: "Remove the whole build cache rather than only unreferenced layers")
        var all = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let client = ContainerClient()
            let container = try await client.get(id: "buildkit")
            try ensureRunning(container: container)

            var arguments = ["buildctl", "prune"]
            if let keepStorage {
                // buildctl takes the kept amount in megabytes.
                arguments += ["--keep-storage", "\(try Parser.memoryStringAsMiB(keepStorage))"]
            }
            if all {
                arguments.append("--all")
            }

            var config = container.configuration.initProcess
            config.executable = arguments[0]
            config.arguments = [String](arguments.dropFirst())
            config.terminal = false

            let io = try ProcessIO.create(tty: false, interactive: false, detach: false)
            defer {
                try? io.close()
            }
            let process = try await client.createProcess(
                containerId: container.id,
                processId: UUID().uuidString.lowercased(),
                configuration: config,
                stdio: io.stdio
            )
            let exitCode = try await io.handleProcess(process: process, log: log)
            guard exitCode == 0 else {
                throw ContainerizationError(.internalError, message: "buildctl prune exited \(exitCode)")
            }

            // buildkit releases the pruned files a beat after buildctl prune
            // returns, so a discard taken in the same breath reads the disk
            // before they land. Trim until two passes in a row hand back
            // nothing, so the verb leaves with everything the guest freed
            // returned to the host.
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            var totalTrimmed: UInt64 = 0
            var idlePasses = 0
            for _ in 0..<8 {
                try await Task.sleep(for: .seconds(3))
                let trimmed = try await client.trim(id: "buildkit")
                totalTrimmed += trimmed
                if trimmed == 0 {
                    idlePasses += 1
                    if idlePasses >= 2 { break }
                } else {
                    idlePasses = 0
                }
            }
            print("returned \(formatter.string(fromByteCount: Int64(totalTrimmed)))")
        }
    }
}
