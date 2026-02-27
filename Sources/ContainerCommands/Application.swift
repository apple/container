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
import ContainerLog
import ContainerPlugin
import ContainerVersion
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import TerminalProgress

// This logger is only used until `asyncCommand.run()`.
// `log` is updated only once in the `validate()` method.
private nonisolated(unsafe) var bootstrapLogger = {
    LoggingSystem.bootstrap({ _ in StderrLogHandler() })
    var log = Logger(label: "com.apple.container")
    log.logLevel = .info
    return log
}()

public struct Application: AsyncLoggableCommand {
    @OptionGroup
    public var logOptions: Flags.Logging

    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "container",
        abstract: "A container platform for macOS",
        version: ReleaseVersion.singleLine(appName: "container CLI"),
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
                    ContainerRun.self,
                    ContainerStart.self,
                    ContainerStats.self,
                    ContainerStop.self,
                    ContainerPrune.self,
                    ContainerExport.self,
                ]
            ),
            CommandGroup(
                name: "Image",
                subcommands: [
                    BuildCommand.self,
                    ImageCommand.self,
                    RegistryCommand.self,
                ]
            ),
            CommandGroup(
                name: "Volume",
                subcommands: [
                    VolumeCommand.self
                ]
            ),
            CommandGroup(
                name: "Other",
                subcommands: Self.otherCommands()
            ),
        ],
        // Hidden command to handle plugins on unrecognized input.
        defaultSubcommand: DefaultCommand.self
    )

    public static func main() async throws {
        restoreCursorAtExit()

        #if DEBUG
        let warning = "Running debug build. Performance may be degraded."
        let formattedWarning: String
        if isatty(FileHandle.standardError.fileDescriptor) == 1 {
            formattedWarning = "\u{001B}[33mWarning!\u{001B}[0m \(warning)\n"
        } else {
            formattedWarning = "Warning! \(warning)\n"
        }
        let warningData = Data(formattedWarning.utf8)
        FileHandle.standardError.write(warningData)
        #endif

        let fullArgs = CommandLine.arguments
        let args = Array(fullArgs.dropFirst())
        let normalizedArgs = Self.normalizeGlobalFlags(args)

        do {
            // container -> defaultHelpCommand
            var command = try Application.parseAsRoot(normalizedArgs)
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
                let pluginLoader = try? await createPluginLoader()
                await Self.printModifiedHelpText(pluginLoader: pluginLoader)
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

    public static func createPluginLoader() async throws -> PluginLoader {
        let installRoot = CommandLine.executablePathUrl
            .deletingLastPathComponent()
            .appendingPathComponent("..")
            .standardized
        let pluginsURL = PluginLoader.userPluginsDir(installRoot: installRoot)
        var directoryExists: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: pluginsURL.path, isDirectory: &directoryExists)
        let userPluginsURL = directoryExists.boolValue ? pluginsURL : nil

        // plugins built into the application installed as a macOS app bundle
        let appBundlePluginsURL = Bundle.main.resourceURL?.appending(path: "plugins")

        // plugins built into the application installed as a Unix-like application
        let installRootPluginsURL =
            installRoot
            .appendingPathComponent("libexec")
            .appendingPathComponent("container")
            .appendingPathComponent("plugins")
            .standardized

        let pluginDirectories = [
            userPluginsURL,
            appBundlePluginsURL,
            installRootPluginsURL,
        ].compactMap { $0 }

        let pluginFactories: [any PluginFactory] = [
            DefaultPluginFactory(),
            AppBundlePluginFactory(),
        ]

        guard let systemHealth = try? await ClientHealthCheck.ping(timeout: .seconds(10)) else {
            throw ContainerizationError(.timeout, message: "unable to retrieve application data root from API server")
        }
        return try PluginLoader(
            appRoot: systemHealth.appRoot,
            installRoot: systemHealth.installRoot,
            logRoot: systemHealth.logRoot,
            pluginDirectories: pluginDirectories,
            pluginFactories: pluginFactories,
            log: bootstrapLogger
        )
    }

    public func validate() throws {
        // Not really a "validation", but a cheat to run this before
        // any of the commands do their business.
        let debugEnvVar = ProcessInfo.processInfo.environment["CONTAINER_DEBUG"]
        if self.logOptions.debug || debugEnvVar != nil {
            bootstrapLogger.logLevel = .debug
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

    private static func otherCommands() -> [any ParsableCommand.Type] {
        guard #available(macOS 26, *) else {
            return [
                BuilderCommand.self,
                SystemCommand.self,
            ]
        }

        return [
            BuilderCommand.self,
            NetworkCommand.self,
            SystemCommand.self,
        ]
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
}

extension Application {
    // Because we support plugins, we need to modify the help text to display
    // any if we found some.
    static func printModifiedHelpText(pluginLoader: PluginLoader?) async {
        let original = Application.helpMessage(for: Application.self)
        guard let pluginLoader else {
            print(original)
            print("PLUGINS: not available, run `container system start`")
            return
        }
        let altered = pluginLoader.alterCLIHelpText(original: original)
        print(altered)
    }

    public enum ListFormat: String, CaseIterable, ExpressibleByArgument {
        case json
        case table
    }

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

    // ArgumentParser expects global flags to appear before the subcommand they
    // apply to. Users frequently pass `--debug` after the subcommand (for example
    // `container run --debug …`), which previously triggered the unhelpful
    // "Unknown option" error. To provide the desired UX, collect any known
    // global flags before that subcommand while respecting `--` passthrough so
    // container process arguments remain untouched.
    private static func normalizeGlobalFlags(_ arguments: [String]) -> [String] {
        var collectedGlobals: [String] = []
        var remaining: [String] = []
        var passthrough = false

        for argument in arguments {
            if !passthrough {
                if argument == "--" {
                    passthrough = true
                    remaining.append(argument)
                    continue
                }

                if Self.globalFlags.contains(argument) {
                    collectedGlobals.append(argument)
                    continue
                }
            }

            remaining.append(argument)
        }

        return collectedGlobals + remaining
    }

    private static var globalFlags: Set<String> {
        ["--debug"]
    }
}
