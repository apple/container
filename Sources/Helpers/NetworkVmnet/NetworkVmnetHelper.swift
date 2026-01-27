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
import ContainerLog
import ContainerVersion
import Logging

@main
struct NetworkVmnetHelper: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-network-vmnet",
        abstract: "XPC service for managing a vmnet network",
        version: ReleaseVersion.singleLine(appName: "container-network-vmnet"),
        subcommands: [
            Start.self
        ]
    )

    static func setupLogger(id: String, debug: Bool) -> Logger {
        LoggingSystem.bootstrap { label in
            OSLogHandler(
                label: label,
                category: "NetworkVmnetHelper"
            )
        }
        var log = Logger(label: "com.apple.container")
        if debug {
            log.logLevel = .debug
        }
        log[metadataKey: "id"] = "\(id)"
        return log
    }
}
