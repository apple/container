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

import Foundation

struct CommandResult: Sendable {
    let outputData: Data
    let errorData: Data
    let status: Int32

    var output: String {
        String(data: outputData, encoding: .utf8) ?? ""
    }

    var error: String {
        String(data: errorData, encoding: .utf8) ?? ""
    }

    @discardableResult
    func check(_ message: String? = nil) throws -> CommandResult {
        guard status == 0 else {
            let detail = message ?? error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandError.nonZeroExit(status, detail)
        }
        return self
    }
}

enum CommandError: Error {
    case binaryNotFound
    case executionFailed(String)
    case nonZeroExit(Int32, String)
}
