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
//  Errors.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/18/25.
//

import ContainerCLI
import Foundation

//extension Application {
enum YamlError: Error, LocalizedError {
    case composeFileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .composeFileNotFound(let path):
            return "compose.yml not found at \(path)"
        }
    }
}

enum ComposeError: Error, LocalizedError {
    case imageNotFound(String)
    case invalidProjectName

    var errorDescription: String? {
        switch self {
        case .imageNotFound(let name):
            return "Service \(name) must define either 'image' or 'build'."
        case .invalidProjectName:
            return "Could not find project name."
        }
    }
}

enum TerminalError: Error, LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        "Command failed: \(self)"
    }
}

/// An enum representing streaming output from either `stdout` or `stderr`.
enum CommandOutput {
    case stdout(String)
    case stderr(String)
    case exitCode(Int32)
}
//}
