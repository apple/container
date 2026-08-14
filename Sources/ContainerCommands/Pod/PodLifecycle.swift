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
import ContainerResource
import ContainerizationError
import ContainerizationExtras
import Foundation

extension Application.PodCommand {
    public struct PodStart: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Boot a pod's machine, with the containers in it"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Pods to start")
        var names: [String]

        public init() {}

        public func run() async throws {
            // The caller's agent rides into every member the machine boots,
            // the donation each sibling boot path carries.
            var dynamicEnv: [String: String] = [:]
            if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
                dynamicEnv["SSH_AUTH_SOCK"] = agent
            }
            for name in names {
                try await ClientPod.start(name, dynamicEnv: dynamicEnv)
                print(name)
            }
        }
    }

    public struct PodStop: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop a pod's machine, and with it every container inside"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Pods to stop")
        var names: [String]

        public init() {}

        public func run() async throws {
            for name in names {
                try await ClientPod.stop(name)
                print(name)
            }
        }
    }

    public struct PodDelete: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete one or more pods",
            aliases: ["rm"]
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Flag(name: .shortAndLong, help: "Delete the pod's containers along with it")
        var force: Bool = false

        @Argument(help: "Pods to delete")
        var names: [String]

        public init() {}

        public func run() async throws {
            for name in names {
                try await ClientPod.delete(name, force: force)
                print(name)
            }
        }
    }

    public struct PodUpdate: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "Hold a running pod to a memory size, which its containers share"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(
            name: .shortAndLong,
            help: """
                Memory the pod's machine is to hold (1MiByte granularity), with optional K, M, G, \
                T, or P suffix. The guest gives back the difference, and takes it again when the \
                size is raised.
                """
        )
        var memory: String

        @Argument(help: "Pod to hold")
        var name: String

        public init() {}

        public func run() async throws {
            let bytes = try Parser.memoryStringAsMiB(memory).mib()
            try await ClientPod.update(name, memoryInBytes: bytes)
            print(name)
        }
    }

    public struct PodInspect: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Display information about one or more pods"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Pods to inspect")
        var names: [String]

        public init() {}

        public func run() async throws {
            var snapshots: [PodSnapshot] = []
            for name in Set(names).sorted() {
                snapshots.append(try await ClientPod.inspect(name))
            }
            try Output.emit(Output.renderJSON(snapshots, options: .pretty))
        }
    }

    public struct PodList: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List pods",
            aliases: ["ls"]
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Flag(name: .shortAndLong, help: "Only output the pod names")
        var quiet: Bool = false

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        public init() {}

        public func run() async throws {
            let pods = try await ClientPod.list()
            try Output.render(payload: pods, display: pods, format: format, quiet: quiet)
        }
    }
}
