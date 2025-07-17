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
import ContainerClient

extension Application.VolumeCommand {
    struct VolumeList: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List volumes",
            aliases: ["ls"]
        )

        @Option(name: .long, help: "Provide filter values (e.g., 'dangling=true')")
        var filter: [String] = []

        @Flag(name: .shortAndLong, help: "Only display volume names")
        var quiet: Bool = false

        func run() async throws {
            print("TODO: List volumes")
            print("Filters: \(filter)")
            print("Quiet: \(quiet)")
        }
    }
}
