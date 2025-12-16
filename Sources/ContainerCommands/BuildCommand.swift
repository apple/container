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

import ArgumentParser
import ContainerBuild
import ContainerClient
import ContainerImagesServiceClient
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import NIO
import TerminalProgress

extension Application {
    public struct BuildCommand: AsyncParsableCommand {
        public init() {}
        public static var configuration: CommandConfiguration {
            var config = CommandConfiguration()
            config.commandName = "build"
            config.abstract = "Build an image from a Dockerfile or Containerfile"
            config._superCommandName = "container"
            config.helpNames = NameSpecification(arrayLiteral: .customShort("h"), .customLong("help"))
            return config
        }

        enum ProgressType: String, ExpressibleByArgument {
            case auto
            case plain
            case tty
        }

        @Option(
            name: .shortAndLong,
            help: ArgumentHelp("Add the architecture type to the build", valueName: "value"),
            transform: { val in val.split(separator: ",").map { String($0) } }
        )
        var arch: [[String]] = {
            [[Arch.hostArchitecture().rawValue]]
        }()

        @Option(name: .long, help: ArgumentHelp("Set build-time variables", valueName: "key=val"))
        var buildArg: [String] = []

        @Option(name: .long, help: ArgumentHelp("Cache imports for the build", valueName: "value", visibility: .hidden))
        var cacheIn: [String] = {
            []
        }()

        @Option(name: .long, help: ArgumentHelp("Cache exports for the build", valueName: "value", visibility: .hidden))
        var cacheOut: [String] = {
            []
        }()

        @Option(name: .shortAndLong, help: "Number of CPUs to allocate to the builder container")
        var cpus: Int64 = 2

        @Option(name: .shortAndLong, help: ArgumentHelp("Path to Dockerfile", valueName: "path"))
        var file: String?

        @Option(name: .shortAndLong, help: ArgumentHelp("Set a label", valueName: "key=val"))
        var label: [String] = []

        @Option(
            name: .shortAndLong,
            help: "Amount of builder container memory (1MiByte granularity), with optional K, M, G, T, or P suffix"
        )
        var memory: String = "2048MB"

        @Flag(name: .long, help: "Do not use cache")
        var noCache: Bool = false

        @Option(name: .shortAndLong, help: ArgumentHelp("Output configuration for the build (format: type=<oci|tar|local>[,dest=])", valueName: "value"))
        var output: [String] = {
            ["type=oci"]
        }()

        @Option(
            name: .long,
            help: ArgumentHelp("Add the OS type to the build", valueName: "value"),
            transform: { val in val.split(separator: ",").map { String($0) } }
        )
        var os: [[String]] = {
            [["linux"]]
        }()

        @Option(
            name: .long,
            help: "Add the platform to the build (format: os/arch[/variant], takes precedence over --os and --arch)",
            transform: { val in val.split(separator: ",").map { String($0) } }
        )
        var platform: [[String]] = [[]]

        @Option(name: .long, help: ArgumentHelp("Progress type (format: auto|plain|tty)", valueName: "type"))
        var progress: ProgressType = .auto

        @Flag(name: .shortAndLong, help: "Suppress build output")
        var quiet: Bool = false

        @Option(name: [.short, .customLong("tag")], help: ArgumentHelp("Name for the built image", valueName: "name"))
        var targetImageNames: [String] = {
            [UUID().uuidString.lowercased()]
        }()

        @Option(name: .long, help: ArgumentHelp("Set the target build stage", valueName: "stage"))
        var target: String = ""

        @Option(name: .long, help: ArgumentHelp("Builder shim vsock port", valueName: "port"))
        var vsockPort: UInt32 = 8088

        @Argument(help: "Build directory")
        var contextDir: String = "."

        public func run() async throws {
            do {
                let timeout: Duration = .seconds(300)
                let progressConfig = try ProgressConfig(
                    showTasks: true,
                    showItems: true
                )
                let progress = ProgressBar(config: progressConfig)
                defer {
                    progress.finish()
                }
                progress.start()

                progress.set(description: "Dialing builder")

                let builder: Builder? = try await withThrowingTaskGroup(of: Builder.self) { [vsockPort, cpus, memory] group in
                    defer {
                        group.cancelAll()
                    }

                    group.addTask { [vsockPort, cpus, memory] in
                        while true {
                            do {
                                let container = try await ClientContainer.get(id: "buildkit")
                                let fh = try await container.dial(vsockPort)

                                let threadGroup: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
                                let b = try Builder(socket: fh, group: threadGroup)

                                // If this call succeeds, then BuildKit is running.
                                let _ = try await b.info()
                                return b
                            } catch {
                                // If we get here, "Dialing builder" is shown for such a short period
                                // of time that it's invisible to the user.
                                progress.set(tasks: 0)
                                progress.set(totalTasks: 3)

                                try await BuilderStart.start(
                                    cpus: cpus,
                                    memory: memory,
                                    progressUpdate: progress.handler
                                )

                                // wait (seconds) for builder to start listening on vsock
                                try await Task.sleep(for: .seconds(5))
                                continue
                            }
                        }
                    }

                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw ValidationError(
                            """
                                Timeout waiting for connection to builder
                            """
                        )
                    }

                    return try await group.next()
                }

                guard let builder else {
                    throw ValidationError("builder is not running")
                }

                let buildFilePath: String
                if let file = self.file {
                    buildFilePath = file
                } else {
                    guard
                        let resolvedPath = try BuildFile.resolvePath(
                            contextDir: self.contextDir,
                            log: log
                        )
                    else {
                        throw ValidationError("failed to find Dockerfile or Containerfile in the context directory \(self.contextDir)")
                    }
                    buildFilePath = resolvedPath
                }

                let buildFileData: Data
                // Dockerfile should be read from stdin
                if file == "-" {
                    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("Dockerfile-\(UUID().uuidString)")
                    defer {
                        try? FileManager.default.removeItem(at: tempFile)
                    }

                    guard FileManager.default.createFile(atPath: tempFile.path(), contents: nil) else {
                        throw ContainerizationError(.internalError, message: "unable to create temporary file")
                    }

                    guard let fileHandle = try? FileHandle(forWritingTo: tempFile) else {
                        throw ContainerizationError(.internalError, message: "unable to open temporary file for writing")
                    }

                    let bufferSize = 4096
                    while true {
                        let chunk = FileHandle.standardInput.readData(ofLength: bufferSize)
                        if chunk.isEmpty { break }
                        fileHandle.write(chunk)
                    }
                    try fileHandle.close()
                    buildFileData = try Data(contentsOf: URL(filePath: tempFile.path()))
                } else {
                    buildFileData = try Data(contentsOf: URL(filePath: buildFilePath))
                }

                let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
                let exportPath = systemHealth.appRoot
                    .appendingPathComponent(Application.BuilderCommand.builderResourceDir)
                let buildID = UUID().uuidString
                let tempURL = exportPath.appendingPathComponent(buildID)
                try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)
                defer {
                    try? FileManager.default.removeItem(at: tempURL)
                }

                let imageNames: [String] = try targetImageNames.map { name in
                    let parsedReference = try Reference.parse(name)
                    parsedReference.normalize()
                    return parsedReference.description
                }

                var terminal: Terminal?
                switch self.progress {
                case .tty:
                    terminal = try Terminal(descriptor: STDERR_FILENO)
                case .auto:
                    terminal = try? Terminal(descriptor: STDERR_FILENO)
                case .plain:
                    terminal = nil
                }

                defer { terminal?.tryReset() }

                let exports: [Builder.BuildExport] = try output.map { output in
                    var exp = try Builder.BuildExport(from: output)
                    if exp.destination == nil {
                        exp.destination = tempURL.appendingPathComponent("out.tar")
                    }
                    return exp
                }

                try await withThrowingTaskGroup(of: Void.self) { [terminal] group in
                    defer {
                        group.cancelAll()
                    }
                    group.addTask {
                        let handler = AsyncSignalHandler.create(notify: [SIGTERM, SIGINT, SIGUSR1, SIGUSR2])
                        for await sig in handler.signals {
                            throw ContainerizationError(.interrupted, message: "exiting on signal \(sig)")
                        }
                    }
                    let platforms: Set<Platform> = try {
                        var results: Set<Platform> = []
                        for platform in (self.platform.flatMap { $0 }) {
                            guard let p = try? Platform(from: platform) else {
                                throw ValidationError("invalid platform specified \(platform)")
                            }
                            results.insert(p)
                        }

                        if !results.isEmpty {
                            return results
                        }

                        for o in (self.os.flatMap { $0 }) {
                            for a in (self.arch.flatMap { $0 }) {
                                guard let platform = try? Platform(from: "\(o)/\(a)") else {
                                    throw ValidationError("invalid os/architecture combination \(o)/\(a)")
                                }
                                results.insert(platform)
                            }
                        }
                        return results
                    }()
                    group.addTask { [terminal, buildArg, contextDir, label, noCache, target, quiet, cacheIn, cacheOut] in
                        let config = Builder.BuildConfig(
                            buildID: buildID,
                            contentStore: RemoteContentStoreClient(),
                            buildArgs: buildArg,
                            contextDir: contextDir,
                            dockerfile: buildFileData,
                            labels: label,
                            noCache: noCache,
                            platforms: [Platform](platforms),
                            terminal: terminal,
                            tags: imageNames,
                            target: target,
                            quiet: quiet,
                            exports: exports,
                            cacheIn: cacheIn,
                            cacheOut: cacheOut
                        )
                        progress.finish()

                        try await builder.build(config)
                    }

                    try await group.next()
                }

                let unpackProgressConfig = try ProgressConfig(
                    description: "Unpacking built image",
                    itemsName: "entries",
                    showTasks: exports.count > 1,
                    totalTasks: exports.count
                )
                let unpackProgress = ProgressBar(config: unpackProgressConfig)
                defer {
                    unpackProgress.finish()
                }
                unpackProgress.start()

                var finalMessage = "Successfully built \(imageNames.joined(separator: ", "))"
                let taskManager = ProgressTaskCoordinator()
                // Currently, only a single export can be specified.
                for exp in exports {
                    unpackProgress.add(tasks: 1)
                    let unpackTask = await taskManager.startTask()
                    switch exp.type {
                    case "oci":
                        try Task.checkCancellation()
                        guard let dest = exp.destination else {
                            throw ContainerizationError(.invalidArgument, message: "dest is required \(exp.rawValue)")
                        }
                        let loaded = try await ClientImage.load(from: dest.absolutePath())

                        for image in loaded {
                            try Task.checkCancellation()
                            try await image.unpack(platform: nil, progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: unpackProgress.handler))

                            // Tag the unpacked image with all requested tags
                            for tagName in imageNames {
                                try Task.checkCancellation()
                                _ = try await image.tag(new: tagName)
                            }
                        }
                    case "tar":
                        guard let dest = exp.destination else {
                            throw ContainerizationError(.invalidArgument, message: "dest is required \(exp.rawValue)")
                        }
                        let tarURL = tempURL.appendingPathComponent("out.tar")
                        try FileManager.default.moveItem(at: tarURL, to: dest)
                        finalMessage = "Successfully exported to \(dest.absolutePath())"
                    case "local":
                        guard let dest = exp.destination else {
                            throw ContainerizationError(.invalidArgument, message: "dest is required \(exp.rawValue)")
                        }
                        let localDir = tempURL.appendingPathComponent("local")

                        guard FileManager.default.fileExists(atPath: localDir.path) else {
                            throw ContainerizationError(.invalidArgument, message: "expected local output not found")
                        }
                        try FileManager.default.copyItem(at: localDir, to: dest)
                        finalMessage = "Successfully exported to \(dest.absolutePath())"
                    default:
                        throw ContainerizationError(.invalidArgument, message: "invalid exporter \(exp.rawValue)")
                    }
                }
                await taskManager.finish()
                unpackProgress.finish()
                print(finalMessage)
            } catch {
                throw NSError(domain: "Build", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
            }
        }

        public func validate() throws {
            // NOTE: We'll "validate" the Dockerfile later.
            guard FileManager.default.fileExists(atPath: contextDir) else {
                throw ValidationError("context dir does not exist \(contextDir)")
            }
            for name in targetImageNames {
                guard let _ = try? Reference.parse(name) else {
                    throw ValidationError("invalid reference \(name)")
                }
            }
        }
    }
}
