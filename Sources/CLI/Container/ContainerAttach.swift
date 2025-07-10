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

import ArgumentParser
import ContainerClient
import ContainerizationError
import ContainerizationOS
import Foundation

extension Application {
    struct ContainerAttach: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "attach",
            abstract: "Attach to a running container with PTY session support")

        @OptionGroup
        var global: Flags.Global
        
        @Flag(name: .long, help: "Do not send buffered history when attaching")
        var noHistory = false
        
        @Option(name: .customLong("detach-keys"), help: "Override the key sequence for detaching a container")
        var detachKeys: String?

        @Argument(help: "Container ID or name to attach to")
        var container: String

        func run() async throws {
            // Get container info
            let container = try await ClientContainer.get(id: container)
            try ensureRunning(container: container)
            
            // Check if container has terminal enabled
            guard container.configuration.initProcess.terminal else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Cannot attach to container without terminal enabled"
                )
            }
            
            log.info("Attaching to container", metadata: ["container": "\(container.id)"])
            
            // Create attach client process
            let process = try await container.attachToSession(sendHistory: !noHistory)
            
            // Run the attached session
            let exitCode = try await runAttachedSession(process: process)
            
            if exitCode != 0 {
                throw ArgumentParser.ExitCode(exitCode)
            }
        }
        
        private func runAttachedSession(process: ClientProcess) async throws -> Int32 {
            // Get handles from the attach response
            let handles = try await process.getAttachHandles()
            
            // Create ProcessIO for the attached session with detach key support
            let io = try ProcessIO.createServerOwned(tty: true, handles: handles, detachKeys: detachKeys)
            
            // Run with standard process handling
            return try await Application.handleProcess(
                io: io,
                process: process,
                serverOwnedStdio: true
            )
        }
    }
}