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
import ContainerClient
import ContainerCommands

@main
public struct ContainerCLI: AsyncParsableCommand {
    public init() {}

    @Argument(parsing: .captureForPassthrough)
    var arguments: [String] = []

    public static let configuration = Application.configuration

    public static func main() async throws {
        try await Application.main()
    }

    public func run() async throws {
        let normalizedArguments = Self.normalizeGlobalFlags(arguments)
        var application = try Application.parse(normalizedArguments)
        try application.validate()
        try application.run()
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
