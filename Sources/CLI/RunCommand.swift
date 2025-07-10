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
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import NIOCore
import NIOPosix
import TerminalProgress

extension Application {
    struct ContainerRunCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a container")

        @OptionGroup
        var processFlags: Flags.Process

        @OptionGroup
        var resourceFlags: Flags.Resource

        @OptionGroup
        var managementFlags: Flags.Management

        @OptionGroup
        var registryFlags: Flags.Registry

        @OptionGroup
        var global: Flags.Global

        @OptionGroup
        var progressFlags: Flags.Progress

        @Flag(name: .long, help: "Use legacy client-owned stdio (for compatibility)")
        var legacyStdio = false

        @Argument(help: "Image name")
        var image: String

        @Argument(parsing: .captureForPassthrough, help: "Container init process arguments")
        var arguments: [String] = []

        func run() async throws {
            var exitCode: Int32 = 127
            let id = Utility.createContainerID(name: self.managementFlags.name)

            var progressConfig: ProgressConfig
            if progressFlags.disableProgressUpdates {
                progressConfig = try ProgressConfig(disableProgressUpdates: progressFlags.disableProgressUpdates)
            } else {
                progressConfig = try ProgressConfig(
                    showTasks: true,
                    showItems: true,
                    ignoreSmallSize: true,
                    totalTasks: 6
                )
            }

            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            try Utility.validEntityName(id)

            // Check if container with id already exists.
            let existing = try? await ClientContainer.get(id: id)
            guard existing == nil else {
                throw ContainerizationError(
                    .exists,
                    message: "container with id \(id) already exists"
                )
            }

            let ck = try await Utility.containerConfigFromFlags(
                id: id,
                image: image,
                arguments: arguments,
                process: processFlags,
                management: managementFlags,
                resource: resourceFlags,
                registry: registryFlags,
                progressUpdate: progress.handler
            )

            progress.set(description: "Starting container")

            let options = ContainerCreateOptions(autoRemove: managementFlags.remove)
            let container = try await ClientContainer.create(
                configuration: ck.0,
                options: options,
                kernel: ck.1
            )

            let detach = self.managementFlags.detach

            let process = try await container.bootstrap()
            progress.finish()

            do {
                // Use server-owned stdio by default unless legacy flag is set
                let useLegacyStdio = self.legacyStdio || ProcessInfo.processInfo.environment["CONTAINER_LEGACY_STDIO"] != nil
                
                if !self.managementFlags.cidfile.isEmpty {
                    let path = self.managementFlags.cidfile
                    let data = id.data(using: .utf8)
                    var attributes = [FileAttributeKey: Any]()
                    attributes[.posixPermissions] = 0o644
                    let success = FileManager.default.createFile(
                        atPath: path,
                        contents: data,
                        attributes: attributes
                    )
                    guard success else {
                        throw ContainerizationError(
                            .internalError, message: "failed to create cidfile at \(path): \(errno)")
                    }
                }

                if detach {
                    // Check if we should use server-owned stdio for detached containers
                    // If -it is specified, user likely wants to attach later
                    let useServerStdioForDetach = !useLegacyStdio && self.processFlags.interactive && self.processFlags.tty
                    
                    if useServerStdioForDetach {
                        // Use server-owned stdio even when detached (for later attach)
                        let handles = try await process.startWithServerStdio()
                        // For detached mode, we don't need ProcessIO - just close client handles
                        // NOTE: The handles we receive are duplicates from XPC, so closing them
                        // should not affect the original handles in the PTYSession
                        if let stdin = handles[0] {
                            try stdin.close()
                        }
                        if let stdout = handles[1] {
                            try stdout.close()
                        }
                        if let stderr = handles[2] {
                            try stderr.close()
                        }
                    } else {
                        // Legacy path for detached containers
                        let io = try ProcessIO.create(
                            tty: self.processFlags.tty,
                            interactive: self.processFlags.interactive,
                            detach: detach,
                            detachKeys: self.processFlags.detachKeys
                        )
                        try await process.start(io.stdio)
                        defer {
                            try? io.close()
                        }
                        try io.closeAfterStart()
                    }
                    print(id)
                    return
                }

                // Set up signal threshold handler for non-TTY mode
                if !self.processFlags.tty {
                    var handler = SignalThreshold(threshold: 3, signals: [SIGINT, SIGTERM])
                    handler.start {
                        print("Received 3 SIGINT/SIGTERM's, forcefully exiting.")
                        Darwin.exit(1)
                    }
                }
                
                // Determine if we should use server-owned stdio
                // Use server-owned stdio when we have both interactive and tty flags, unless legacy is forced
                let useServerStdio = !useLegacyStdio && self.processFlags.interactive && self.processFlags.tty
                
                if useServerStdio {
                    // Server-owned stdio path
                    let handles = try await process.startWithServerStdio()
                    let io = try ProcessIO.createServerOwned(tty: true, handles: handles, detachKeys: self.processFlags.detachKeys)
                    exitCode = try await Application.handleProcess(io: io, process: process, serverOwnedStdio: true)
                } else {
                    // Legacy client-owned stdio path
                    let actualTty = self.processFlags.tty
                    let io = try ProcessIO.create(
                        tty: actualTty,
                        interactive: self.processFlags.interactive,
                        detach: detach,
                        detachKeys: self.processFlags.detachKeys
                    )
                    exitCode = try await Application.handleProcess(io: io, process: process)
                }
            } catch {
                if error is ContainerizationError {
                    throw error
                }
                throw ContainerizationError(.internalError, message: "failed to run container: \(error)")
            }
            throw ArgumentParser.ExitCode(exitCode)
        }
    }
}

struct ProcessIO {
    let stdin: Pipe?
    let stdout: Pipe?
    let stderr: Pipe?
    var ioTracker: IoTracker?
    let detachKeyDetector: DetachKeyDetector?

    struct IoTracker {
        let stream: AsyncStream<Void>
        let cont: AsyncStream<Void>.Continuation
        let configuredStreams: Int
    }

    let stdio: [FileHandle?]

    let console: Terminal?

    func closeAfterStart() throws {
        try stdin?.fileHandleForReading.close()
        try stdout?.fileHandleForWriting.close()
        try stderr?.fileHandleForWriting.close()
    }

    func close() throws {
        try console?.reset()
    }

    static func create(tty: Bool, interactive: Bool, detach: Bool, serverOwned: Bool = false, detachKeys: String? = nil) throws -> ProcessIO {
        // If server-owned, we'll get handles later
        if serverOwned {
            return .init(
                stdin: nil,
                stdout: nil,
                stderr: nil,
                ioTracker: nil,
                detachKeyDetector: nil,
                stdio: [nil, nil, nil],
                console: nil
            )
        }
        
        let current: Terminal? = try {
            if !tty || !interactive {
                return nil
            }
            // Try to get current terminal, but gracefully handle test environments
            if let current = try? Terminal.current {
                try current.setraw()
                return current
            }
            return nil
        }()

        var stdio = [FileHandle?](repeating: nil, count: 3)

        // Create detach key detector early if we need it
        let detachKeyDetector: DetachKeyDetector? = {
            if interactive && tty && !detach {
                let sequence = detachKeys ?? DetachKeys.defaultSequence
                return DetachKeyDetector(sequence: sequence)
            }
            return nil
        }()

        let stdin: Pipe? = {
            if !interactive && !tty {
                return nil
            }
            return Pipe()
        }()

        if let stdin {
            if interactive {
                let pin = FileHandle.standardInput
                pin.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        pin.readabilityHandler = nil
                        return
                    }
                    
                    // Process input through detach key detector if available
                    if let detector = detachKeyDetector {
                        Task {
                            let (shouldDetach, dataToForward) = await detector.processInput(data)
                            if shouldDetach {
                                // Detach sequence detected - stop reading and close handlers
                                pin.readabilityHandler = nil
                                print("\r\nDetaching from container...")
                                return
                            }
                            if !dataToForward.isEmpty {
                                try! stdin.fileHandleForWriting.write(contentsOf: dataToForward)
                            }
                        }
                    } else {
                        // No detector, forward data directly
                        try! stdin.fileHandleForWriting.write(contentsOf: data)
                    }
                }
            }
            stdio[0] = stdin.fileHandleForReading
        }

        let stdout: Pipe? = {
            if detach {
                return nil
            }
            return Pipe()
        }()

        var configuredStreams = 0
        let (stream, cc) = AsyncStream<Void>.makeStream()
        if let stdout {
            configuredStreams += 1
            let pout: FileHandle = {
                if let current {
                    return current.handle
                }
                return .standardOutput
            }()

            let rout = stdout.fileHandleForReading
            rout.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    rout.readabilityHandler = nil
                    cc.yield()
                    return
                }
                try! pout.write(contentsOf: data)
            }
            stdio[1] = stdout.fileHandleForWriting
        }

        let stderr: Pipe? = {
            if detach || tty {
                return nil
            }
            return Pipe()
        }()
        if let stderr {
            configuredStreams += 1
            let perr: FileHandle = .standardError
            let rerr = stderr.fileHandleForReading
            rerr.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    rerr.readabilityHandler = nil
                    cc.yield()
                    return
                }
                try! perr.write(contentsOf: data)
            }
            stdio[2] = stderr.fileHandleForWriting
        }

        var ioTracker: IoTracker? = nil
        if configuredStreams > 0 {
            ioTracker = .init(stream: stream, cont: cc, configuredStreams: configuredStreams)
        }

        return .init(
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            ioTracker: ioTracker,
            detachKeyDetector: detachKeyDetector,
            stdio: stdio,
            console: current
        )
    }

    public func wait() async throws {
        guard let ioTracker = self.ioTracker else {
            return
        }
        do {
            try await Timeout.run(seconds: 3) {
                var counter = ioTracker.configuredStreams
                for await _ in ioTracker.stream {
                    counter -= 1
                    if counter == 0 {
                        ioTracker.cont.finish()
                        break
                    }
                }
            }
        } catch {
            log.error("Timeout waiting for IO to complete : \(error)")
            throw error
        }
    }
    
    static func createServerOwned(tty: Bool, handles: [FileHandle?], detachKeys: String? = nil) throws -> ProcessIO {
        // Set up terminal if TTY mode and terminal is available
        let current: Terminal? = {
            if !tty {
                return nil
            }
            // Try to get current terminal, but don't fail if not available
            if let current = try? Terminal.current {
                try? current.setraw()
                return current
            }
            return nil
        }()
        
        var configuredStreams = 0
        let (stream, cc) = AsyncStream<Void>.makeStream()
        
        // Create detach key detector for TTY mode
        let detachKeyDetector: DetachKeyDetector? = {
            if tty {
                let sequence = detachKeys ?? DetachKeys.defaultSequence
                return DetachKeyDetector(sequence: sequence)
            }
            return nil
        }()
        
        // Set up stdin forwarding from terminal to server handle
        if let stdinHandle = handles[0] {
            let pin = FileHandle.standardInput
            pin.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    pin.readabilityHandler = nil
                    return
                }
                
                // Process input through detach key detector if available
                if let detector = detachKeyDetector {
                    Task {
                        let (shouldDetach, dataToForward) = await detector.processInput(data)
                        if shouldDetach {
                            // Detach sequence detected - stop reading and close handlers
                            pin.readabilityHandler = nil
                            print("\r\nDetaching from container...")
                            return
                        }
                        if !dataToForward.isEmpty {
                            try! stdinHandle.write(contentsOf: dataToForward)
                        }
                    }
                } else {
                    // No detector, forward data directly
                    try! stdinHandle.write(contentsOf: data)
                }
            }
        }
        
        // Set up stdout forwarding from server handle to terminal
        if let stdoutHandle = handles[1] {
            configuredStreams += 1
            let pout: FileHandle = {
                if let current {
                    return current.handle
                }
                return .standardOutput
            }()
            
            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stdoutHandle.readabilityHandler = nil
                    cc.yield()
                    return
                }
                try! pout.write(contentsOf: data)
            }
        }
        
        // Set up stderr forwarding (only if not TTY)
        if !tty, let stderrHandle = handles[2] {
            configuredStreams += 1
            let perr = FileHandle.standardError
            
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stderrHandle.readabilityHandler = nil
                    cc.yield()
                    return
                }
                try! perr.write(contentsOf: data)
            }
        }
        
        var ioTracker: IoTracker? = nil
        if configuredStreams > 0 {
            ioTracker = .init(stream: stream, cont: cc, configuredStreams: configuredStreams)
        }
        
        // Return ProcessIO with no pipes (server owns them)
        return .init(
            stdin: nil,
            stdout: nil,
            stderr: nil,
            ioTracker: ioTracker,
            detachKeyDetector: detachKeyDetector,
            stdio: handles,
            console: current
        )
    }
}
