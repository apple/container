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
import ContainerCommands
import TerminalProgress

@main
struct Application: AsyncParsableCommand {
    public init() {}

    static func main() async {
        // The root CLI's handlers are discarded when it execs into this plugin.
        ProgressBar.restoreCursorAtExit()
        await main(nil)
    }

    public static var configuration: CommandConfiguration {
        var config = CommandConfiguration()
        config.commandName = "build"
        config.abstract = "Build an image from a Dockerfile or Containerfile"
        config.helpNames = NameSpecification(arrayLiteral: .customShort("h"), .customLong("help"))
        return config
    }

    @OptionGroup
    var options: BuildOptions

    func run() async throws {
        let containerSystemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
        try await options.runLinuxBuild(containerSystemConfig: containerSystemConfig)
    }
}
