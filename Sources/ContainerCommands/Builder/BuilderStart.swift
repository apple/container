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
import ContainerBuild
import ContainerPersistence
import TerminalProgress

extension Application {
    public struct BuilderStart: AsyncLoggableCommand {
        public static var configuration: CommandConfiguration {
            var config = CommandConfiguration()
            config.commandName = "start"
            config.abstract = "Start the builder container"
            return config
        }

        @Option(name: .shortAndLong, help: "Number of CPUs to allocate to the builder container")
        var cpus: Int64?

        @Option(
            name: .shortAndLong,
            help: "Amount of builder container memory (1MiByte granularity), with optional K, M, G, T, or P suffix"
        )
        var memory: String?

        @OptionGroup
        public var dns: Flags.DNS

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await Application.loadContainerSystemConfig()
            let progressConfig = try ProgressConfig(
                showTasks: true,
                showItems: true,
                totalTasks: 4
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()
            try await Builder.start(
                cpus: self.cpus,
                memory: self.memory,
                log: log,
                dnsNameservers: self.dns.nameservers,
                dnsDomain: self.dns.domain,
                dnsSearchDomains: self.dns.searchDomains,
                dnsOptions: self.dns.options,
                progressUpdate: progress.handler,
                containerSystemConfig: containerSystemConfig,
            )
            progress.finish()
        }
    }
}
