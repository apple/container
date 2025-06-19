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
//  File.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/18/25.
//

import ArgumentParser
import Foundation
import Yams

struct ComposeCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "compose",
        abstract: "Manage containers with Docker Compose files",
        subcommands: [
            ComposeUp.self,
            ComposeDown.self,
        ])
}

/// A structure representing the result of a command-line process execution.
struct CommandResult {
    /// The standard output captured from the process.
    let stdout: String

    /// The standard error output captured from the process.
    let stderr: String

    /// The exit code returned by the process upon termination.
    let exitCode: Int32
}
