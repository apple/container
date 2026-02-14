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
import ContainerLog
import Logging

extension Application {
    public struct LaunchAgentDisable: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "disable",
            abstract: "Deregister the LaunchAgent to stop the container from starting on user login"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let logger = Logger(label: "LaunchAgentDisable", factory: { _ in StderrLogHandler() })

            do {
                try LaunchAgentServiceManager.deregisterLaunchAgent()
                logger.info("LaunchAgent deregistered and deleted successfully")
            } catch {
                logger.error("Failed to deregister and delete the LaunchAgent", metadata: ["error": "\(error)"])
            }
        }
    }
}
