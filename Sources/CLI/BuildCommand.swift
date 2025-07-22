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
    struct BuildCommand: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            var config = CommandConfiguration()
            config.commandName = "build"
            config.abstract = "Build an image from a Dockerfile"
            config._superCommandName = "container"
            config.helpNames = NameSpecification(arrayLiteral: .customShort("h"), .customLong("help"))
            return config
        }

        @Option(name: [.customLong("cpus"), .customShort("c")], help: "Number of CPUs to allocate to the container")
        public var cpus: Int64 = 2

        @Option(
            name: [.customLong("memory"), .customShort("m")],
            help:
                "Amount of memory in bytes, kilobytes (K), megabytes (M), or gigabytes (G) for the container, with MB granularity (for example, 1024K will result in 1MB being allocated for the container)"
        )
        var memory: String = "2048MB"

        @Option(name: .long, help: ArgumentHelp("Set build-time variables", valueName: "key=val"))
        var buildArg: [String] = []

        @Argument(help: "Build directory")
        var contextDir: String = "."

        @Option(name: .shortAndLong, help: ArgumentHelp("Path to Dockerfile", valueName: "path"))
        var file: String = "Dockerfile"

        @Option(name: .shortAndLong, help: ArgumentHelp("Set a label", valueName: "key=val"))
        var label: [String] = []

        @Flag(name: .long, help: "Do not use cache")
        var noCache: Bool = false

        @Option(name: .shortAndLong, help: ArgumentHelp("Output configuration for the build", valueName: "value"))
        var output: [String] = {
            ["type=oci"]
        }()

        @Option(name: .long, help: ArgumentHelp("Cache imports for the build", valueName: "value", visibility: .hidden))
        var cacheIn: [String] = {
            []
        }()

        @Option(name: .long, help: ArgumentHelp("Cache exports for the build", valueName: "value", visibility: .hidden))
        var cacheOut: [String] = {
            []
        }()

        @Option(name: .long, help: ArgumentHelp("set the build architecture", valueName: "value"))
        var arch: [String] = {
            ["arm64"]
        }()

        @Option(name: .long, help: ArgumentHelp("set the build os", valueName: "value"))
        var os: [String] = {
            ["linux"]
        }()

        @Option(name: .long, help: ArgumentHelp("Progress type - one of [auto|plain|tty]", valueName: "type"))
        var progress: String = "auto"

        @Option(name: .long, help: ArgumentHelp("Builder-shim vsock port", valueName: "port"))
        var vsockPort: UInt32 = 8088

        @Option(name: [.customShort("t"), .customLong("tag")], help: ArgumentHelp("Name for the built image", valueName: "name"))
        var targetImageName: String = UUID().uuidString.lowercased()

        @Option(name: .long, help: ArgumentHelp("Set the target build stage", valueName: "stage"))
        var target: String = ""

        @Flag(name: .shortAndLong, help: "Suppress build output")
        var quiet: Bool = false

        func run() async throws {
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

                let builder: Builder? = try await withThrowingTaskGroup(of: Builder.self) { group in
                    defer {
                        group.cancelAll()
                    }

                    group.addTask {
                        while true {
                            do {
                                let container = try await ClientContainer.get(id: "buildkit")
                                let fh = try await container.dial(self.vsockPort)

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
                                    cpus: self.cpus,
                                    memory: self.memory,
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

                let dockerfile = try Data(contentsOf: URL(filePath: file))
                let exportPath = Application.appRoot.appendingPathComponent(".build")

                let buildID = UUID().uuidString
                let tempURL = exportPath.appendingPathComponent(buildID)
                try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)
                defer {
                    try? FileManager.default.removeItem(at: tempURL)
                }

                let imageName: String = try {
                    let parsedReference = try Reference.parse(targetImageName)
                    parsedReference.normalize()
                    return parsedReference.description
                }()

                var terminal: Terminal?
                switch self.progress {
                case "tty":
                    terminal = try Terminal(descriptor: STDERR_FILENO)
                case "auto":
                    terminal = try? Terminal(descriptor: STDERR_FILENO)
                case "plain":
                    terminal = nil
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid progress mode \(self.progress)")
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
                    let platforms: [Platform] = try {
                        var results: [Platform] = []
                        for o in self.os {
                            for a in self.arch {
                                guard let platform = try? Platform(from: "\(o)/\(a)") else {
                                    throw ValidationError("invalid os/architecture combination \(o)/\(a)")
                                }
                                results.append(platform)
                            }
                        }
                        return results
                    }()
                    group.addTask { [terminal] in
                        let config = ContainerBuild.Builder.BuildConfig(
                            buildID: buildID,
                            contentStore: RemoteContentStoreClient(),
                            buildArgs: buildArg,
                            contextDir: contextDir,
                            dockerfile: dockerfile,
                            labels: label,
                            noCache: noCache,
                            platforms: platforms,
                            terminal: terminal,
                            tag: imageName,
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

                var finalMessage = "Successfully built \(imageName)"
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

        func validate() throws {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("Dockerfile does not exist at path: \(file)")
            }
            guard FileManager.default.fileExists(atPath: contextDir) else {
                throw ValidationError("context dir does not exist \(contextDir)")
            }
            guard let _ = try? Reference.parse(targetImageName) else {
                throw ValidationError("invalid reference \(targetImageName)")
            }
        }
    }
}
