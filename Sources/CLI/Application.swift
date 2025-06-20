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

//

import ArgumentParser
import CVersion
import ContainerClient
import ContainerLog
import ContainerPlugin
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import TerminalProgress

// `log` is updated only once in the `validate()` method.
nonisolated(unsafe) var log = {
    LoggingSystem.bootstrap { label in
        OSLogHandler(
            label: label,
            category: "CLI"
        )
    }
    var log = Logger(label: "com.apple.container")
    log.logLevel = .debug
    return log
}()

@main
struct Application: AsyncParsableCommand {
    @OptionGroup
    var global: Flags.Global

    static let configuration = CommandConfiguration(
        commandName: "container",
        abstract: "A container platform for macOS",
        version: releaseVersion(),
        subcommands: [
            DefaultCommand.self
        ],
        groupedSubcommands: [
            CommandGroup(
                name: "Container",
                subcommands: [
                    ContainerCreate.self,
                    ContainerDelete.self,
                    ContainerExec.self,
                    ContainerInspect.self,
                    ContainerKill.self,
                    ContainerList.self,
                    ContainerLogs.self,
                    ContainerRunCommand.self,
                    ContainerStart.self,
                    ContainerStop.self,
                ]
            ),
            CommandGroup(
                name: "Image",
                subcommands: [
                    BuildCommand.self,
                    ImagesCommand.self,
                    RegistryCommand.self,
                ]
            ),
            CommandGroup(
                name: "System",
                subcommands: [
                    BuilderCommand.self,
                    SystemCommand.self,
                ]
            ),
        ],
        // Hidden command to handle plugins on unrecognized input.
        defaultSubcommand: DefaultCommand.self
    )

    static let appRoot: URL = {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        .appendingPathComponent("com.apple.container")
    }()

    static let pluginLoader: PluginLoader = {
        // create user-installed plugins directory if it doesn't exist
        let pluginsURL = PluginLoader.userPluginsDir(root: Self.appRoot)
        try! FileManager.default.createDirectory(at: pluginsURL, withIntermediateDirectories: true)
        let pluginDirectories = [
            pluginsURL
        ]
        let pluginFactories = [
            DefaultPluginFactory()
        ]

        let statePath = PluginLoader.defaultPluginResourcePath(root: Self.appRoot)
        try! FileManager.default.createDirectory(at: statePath, withIntermediateDirectories: true)
        return PluginLoader(pluginDirectories: pluginDirectories, pluginFactories: pluginFactories, defaultResourcePath: statePath, log: log)
    }()

    func validate() throws {
        // Not really a "validation", but a cheat to run this before
        // any of the commands do their business.
        let debugEnvVar = ProcessInfo.processInfo.environment["CONTAINER_DEBUG"]
        if self.global.debug || debugEnvVar != nil {
            log.logLevel = .debug
        }
        // Ensure we're not running under Rosetta.
        if try isTranslated() {
            throw ValidationError(
                """
                `container` is currently running under Rosetta Translation, which could be
                caused by your terminal application. Please ensure this is turned off.
                """
            )
        }
    }

    private static func restoreCursorAtExit() {
        let signalHandler: @convention(c) (Int32) -> Void = { signal in
            let exitCode = ExitCode(signal + 128)
            Application.exit(withError: exitCode)
        }
        // Termination by Ctrl+C.
        signal(SIGINT, signalHandler)
        // Termination using `kill`.
        signal(SIGTERM, signalHandler)
        // Normal and explicit exit.
        atexit {
            if let progressConfig = try? ProgressConfig() {
                let progressBar = ProgressBar(config: progressConfig)
                progressBar.resetCursor()
            }
        }
    }

    public static func main() async throws {
        restoreCursorAtExit()

        #if DEBUG
        let warning = "Running debug build. Performance may be degraded."
        let formattedWarning = "\u{001B}[33mWarning!\u{001B}[0m \(warning)\n"
        let warningData = Data(formattedWarning.utf8)
        FileHandle.standardError.write(warningData)
        #endif

        let fullArgs = CommandLine.arguments
        let args = Array(fullArgs.dropFirst())

        do {
            // container -> defaultHelpCommand
            var command = try Application.parseAsRoot(args)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            // Regular ol `command` with no args will get caught by DefaultCommand. --help
            // on the root command will land here.
            let containsHelp = fullArgs.contains("-h") || fullArgs.contains("--help")
            if fullArgs.count <= 2 && containsHelp {
                Self.printModifiedHelpText()
                return
            }
            let errorAsString: String = String(describing: error)
            if errorAsString.contains("XPC connection error") {
                let modifiedError = ContainerizationError(.interrupted, message: "\(error)\nEnsure container system service has been started with `container system start`.")
                Application.exit(withError: modifiedError)
            } else {
                Application.exit(withError: error)
            }
        }
    }

    static func handleProcess(io: ProcessIO, process: ClientProcess) async throws -> Int32 {
        let signals = AsyncSignalHandler.create(notify: Application.signalSet)
        return try await withThrowingTaskGroup(of: Int32?.self, returning: Int32.self) { group in
            let waitAdded = group.addTaskUnlessCancelled {
                let code = try await process.wait()
                try await io.wait()
                return code
            }

            guard waitAdded else {
                group.cancelAll()
                return -1
            }

            try await process.start(io.stdio)
            defer {
                try? io.close()
            }
            try io.closeAfterStart()

            if let current = io.console {
                let size = try current.size
                // It's supremely possible the process could've exited already. We shouldn't treat
                // this as fatal.
                try? await process.resize(size)
                _ = group.addTaskUnlessCancelled {
                    let winchHandler = AsyncSignalHandler.create(notify: [SIGWINCH])
                    for await _ in winchHandler.signals {
                        do {
                            try await process.resize(try current.size)
                        } catch {
                            log.error(
                                "failed to send terminal resize event",
                                metadata: [
                                    "error": "\(error)"
                                ]
                            )
                        }
                    }
                    return nil
                }
            } else {
                _ = group.addTaskUnlessCancelled {
                    for await sig in signals.signals {
                        do {
                            try await process.kill(sig)
                        } catch {
                            log.error(
                                "failed to send signal",
                                metadata: [
                                    "signal": "\(sig)",
                                    "error": "\(error)",
                                ]
                            )
                        }
                    }
                    return nil
                }
            }

            while true {
                let result = try await group.next()
                if result == nil {
                    return -1
                }
                let status = result!
                if let status {
                    group.cancelAll()
                    return status
                }
            }
            return -1
        }
    }
}

extension Application {
    // Because we support plugins, we need to modify the help text to display
    // any if we found some.
    static func printModifiedHelpText() {
        let altered = Self.pluginLoader.alterCLIHelpText(
            original: Application.helpMessage(for: Application.self)
        )
        print(altered)
    }

    enum ListFormat: String, CaseIterable, ExpressibleByArgument {
        case json
        case table
    }

    static let signalSet: [Int32] = [
        SIGTERM,
        SIGINT,
        SIGUSR1,
        SIGUSR2,
        SIGWINCH,
    ]

    func isTranslated() throws -> Bool {
        do {
            return try Sysctl.byName("sysctl.proc_translated") == 1
        } catch let posixErr as POSIXError {
            if posixErr.code == .ENOENT {
                return false
            }
            throw posixErr
        }
    }

    private static func releaseVersion() -> String {
        var versionDetails: [String: String] = ["build": "release"]
        #if DEBUG
        versionDetails["build"] = "debug"
        #endif
        #if CURRENT_SDK
        versionDetails["sdk"] = "macOS 15"
        #endif
        let gitCommit = {
            let sha = get_git_commit().map { String(cString: $0) }
            guard let sha else {
                return "unspecified"
            }
            return String(sha.prefix(7))
        }()
        versionDetails["commit"] = gitCommit
        let extras: String = versionDetails.map { "\($0): \($1)" }.sorted().joined(separator: ", ")

        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        let releaseVersion = bundleVersion ?? get_release_version().map { String(cString: $0) } ?? "0.0.0"

        return "container CLI version \(releaseVersion) (\(extras))"
    }
}
