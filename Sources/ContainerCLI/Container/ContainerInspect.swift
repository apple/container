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
import Foundation
import SwiftProtobuf

extension Application {
    struct ContainerInspect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Display information about one or more containers")

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "Containers to inspect")
        var containers: [String]

        func run() async throws {
            let objects: [any Codable] = try await ClientContainer.list().filter {
                containers.contains($0.id)
            }.map {
                PrintableContainer($0)
            }
            print(try objects.jsonArray())
        }
    }
}
