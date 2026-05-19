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
import ContainerizationError

public enum ListFormat: String, CaseIterable, ExpressibleByArgument, Sendable {
    case json
    case table
    case yaml
    case toml

    /// Throws if `self` is not in `supported`. Use from a command's `validate()`
    /// so unimplemented formats fail fast with a clear error instead of silently
    /// falling through to table output.
    public func ensureSupported(_ supported: Set<ListFormat>) throws {
        if !supported.contains(self) {
            let list = supported.map(\.rawValue).sorted().joined(separator: ", ")
            throw ContainerizationError(
                .invalidArgument,
                message: "--format \(self.rawValue) is not supported for this command; supported: \(list)"
            )
        }
    }
}
