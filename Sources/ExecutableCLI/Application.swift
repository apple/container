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

//

//import ContainerCLI
import ArgumentParser
import CVersion
import ContainerClient
import ContainerLog
import ContainerPlugin
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import TerminalProgress

@main
public struct Executable: AsyncParsableCommand {
    public init() {}
    
//    @OptionGroup
//    var global: Flags.Global

    public static let configuration = CommandConfiguration(
        commandName: "container",
        abstract: "A container platform for macOS",
        subcommands: [
        ]
    )

    public static func main() async throws {
//        try await Application.main()
    }

    public func validate() throws {
//        try Application.validate()
    }
}
