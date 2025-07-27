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
import ComposeCore
import ContainerizationError
import Foundation
import Dispatch
#if os(macOS)
import Darwin
#else
import Glibc
#endif


struct ComposeUp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "up",
        abstract: "Create and start containers"
    )
    
    @OptionGroup
    var composeOptions: ComposeOptions
    
    @OptionGroup
    var global: Flags.Global
    
    @Flag(name: [.customLong("detach"), .customShort("d")], help: "Run containers in the background")
    var detach: Bool = false
    
    @Flag(name: .long, help: "Remove containers for services not defined in the Compose file")
    var removeOrphans: Bool = false
    
    @Flag(name: .long, help: "Recreate containers even if their configuration hasn't changed")
    var forceRecreate: Bool = false
    
    @Flag(name: .long, help: "Don't recreate containers if they exist")
    var noRecreate: Bool = false
    
    @Flag(name: .long, help: "Don't start services after creating them")
    var noDeps: Bool = false

    @Flag(name: .long, help: "Automatically remove containers when they exit")
    var rm: Bool = false

    @Option(name: .long, help: "Pull policy: always|missing|never")
    var pull: String = "missing"

    @Flag(name: .long, help: "Wait for services to be running/healthy")
    var wait: Bool = false

    @Option(name: .long, help: "Wait timeout in seconds")
    var waitTimeout: Int?

    @Argument(help: "Services to start")
    var services: [String] = []
    
    func run() async throws {
        // Set environment variables
        composeOptions.loadDotEnvIfPresent()
        composeOptions.setEnvironmentVariables()
        
        // Parse compose files
        let parser = ComposeParser(log: log, allowAnchors: global.allowAnchors)
        let composeFile = try parser.parse(from: composeOptions.getComposeFileURLs())
        
        // Convert to project
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: composeOptions.getProjectName(),
            profiles: composeOptions.profile,
            selectedServices: services
        )
        
        // Create progress handler
        let progressConfig = try ProgressConfig(
            description: "Starting services",
            showTasks: true,
            showItems: false
        )
        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()
        
        // Create orchestrator
        let orchestrator = Orchestrator(log: log)
        
        // Start services
        try await orchestrator.up(
            project: project,
            services: services,
            detach: detach,
            forceRecreate: forceRecreate,
            noRecreate: noRecreate,
            noDeps: noDeps,
            removeOrphans: removeOrphans,
            removeOnExit: rm,
            progressHandler: progress.handler,
            pullPolicy: {
                switch pull.lowercased() {
                case "always": return .always
                case "never": return .never
                default: return .missing
                }
            }(),
            wait: wait,
            waitTimeoutSeconds: waitTimeout
        )
        
        progress.finish()

        // Print final image tags used for services
        if !project.services.isEmpty {
            print("Service images:")
            for (name, svc) in project.services.sorted(by: { $0.key < $1.key }) {
                let image = svc.effectiveImageName(projectName: project.name)
                print("- \(name): \(image)")
            }
            print("")
        }

        // Call out DNS names for service discovery inside the container network
        if !project.services.isEmpty {
            print("Service DNS names:")
            for (name, svc) in project.services.sorted(by: { $0.key < $1.key }) {
                let cname = svc.containerName ?? "\(project.name)_\(name)"
                print("- \(name): \(cname)")
            }
        }
        
        if detach {
            print("Started project '\(project.name)' in detached mode")
        } else {
            // Install signal handlers so Ctrl-C stops services gracefully
            func installSignal(_ signo: Int32) {
                signal(signo, SIG_IGN)
                // Create and retain the signal source on the main queue to satisfy concurrency rules
                DispatchQueue.main.async {
                    let src = DispatchSource.makeSignalSource(signal: signo, queue: .main)
                    src.setEventHandler {
                        // Use a MainActor-isolated flag so the compiler is happy about concurrency
                        Task { @MainActor in
                            // Second signal forces exit
                            if SignalState.shared.seenFirstSignal {
                                Darwin.exit(130)
                            }
                            SignalState.shared.seenFirstSignal = true
                            do {
                                print("\nStopping project '\(project.name)' (Ctrl-C again to force)...")
                                let orchestratorForStop = Orchestrator(log: log)
                                _ = try await orchestratorForStop.down(project: project, removeVolumes: false, removeOrphans: false, progressHandler: nil)
                                Darwin.exit(0)
                            } catch {
                                // If graceful stop fails, exit with error code
                                FileHandle.standardError.write(Data("compose: failed to stop services: \(error)\n".utf8))
                                Darwin.exit(1)
                            }
                        }
                    }
                    src.resume()
                    SignalRetainer.retain(src)
                }
            }
            installSignal(SIGINT)
            installSignal(SIGTERM)

            // Stream logs for selected services (or all if none selected), similar to docker-compose up
            let orchestratorForLogs = Orchestrator(log: log)
            let logStream = try await orchestratorForLogs.logs(
                project: project,
                services: services,
                follow: true,
                tail: nil,
                timestamps: false
            )
            for try await entry in logStream {
                let output = "[\(entry.serviceName)] \(entry.message)"
                switch entry.stream {
                case .stdout:
                    print(output)
                case .stderr:
                    FileHandle.standardError.write(Data((output + "\n").utf8))
                }
            }
        }
    }
}

// A tiny atomic flag helper for one-time behavior across signal handlers
@MainActor
fileprivate final class SignalState {
    static let shared = SignalState()
    var seenFirstSignal = false
}

// Keep strong references to DispatchSourceSignal so handlers fire reliably
@MainActor
fileprivate final class SignalRetainer {
    private static let shared = SignalRetainer()
    private var sources: [DispatchSourceSignal] = []
    static func install() { /* ensure type is loaded */ }
    static func retain(_ src: DispatchSourceSignal) {
        shared.sources.append(src)
    }
}
