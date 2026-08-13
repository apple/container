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

/// Pure classification of options reserved by the Compose plugin itself.
enum ComposeInvocation {
    enum ReservedOption: String, Sendable {
        case completions = "--completions"
        case socketPath = "--socket-path"
    }

    /// Returns whether Compose help was requested for the forwarded command.
    /// Arguments after `--` belong to Compose and are not inspected.
    static func requestsHelp(in arguments: [String]) -> Bool {
        for argument in arguments {
            guard argument != "--" else {
                break
            }
            if argument == "--help" || argument == "-h" {
                return true
            }
        }
        return false
    }

    /// Finds a plugin option that would otherwise be hidden in the captured
    /// Docker Compose argument list. Arguments after `--` belong to Compose.
    static func reservedOption(in arguments: [String]) -> ReservedOption? {
        for argument in arguments {
            guard argument != "--" else {
                break
            }

            let name = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first
            guard let name else {
                continue
            }

            if let option = ReservedOption(rawValue: String(name)) {
                return option
            }
        }
        return nil
    }
}
