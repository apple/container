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
import ContainerVersion
import ContainerizationError
import Darwin
import TerminalProgress

public struct ClusterApplication: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "cluster",
        abstract: "Kubernetes clusters on Apple Containerization",
        version: ReleaseVersion.singleLine(appName: "cluster CLI"),
        subcommands: [
            ClusterCreate.self,
            ClusterDelete.self,
            ClusterStart.self,
            ClusterStop.self,
            ClusterStatus.self,
            ClusterKubeconfig.self,
        ]
    )

    public static func main() async throws {
        restoreCursorAtExit()

        let fullArgs = CommandLine.arguments
        let args = Array(fullArgs.dropFirst())

        do {
            var command = try ClusterApplication.parseAsRoot(args)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            let errorAsString = String(describing: error)
            if errorAsString.contains("XPC connection error") {
                let modifiedError = ContainerizationError(
                    .interrupted,
                    message: "\(error)\nEnsure container system service has been started with `container system start`."
                )
                ClusterApplication.exit(withError: modifiedError)
            } else {
                ClusterApplication.exit(withError: error)
            }
        }
    }

    private static func restoreCursorAtExit() {
        let signalHandler: @convention(c) (Int32) -> Void = { signal in
            let exitCode = ExitCode(signal + 128)
            ClusterApplication.exit(withError: exitCode)
        }
        signal(SIGINT, signalHandler)
        signal(SIGTERM, signalHandler)
        atexit {
            if let progressConfig = try? ProgressConfig() {
                let progressBar = ProgressBar(config: progressConfig)
                progressBar.resetCursor()
            }
        }
    }
}
