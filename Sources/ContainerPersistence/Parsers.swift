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

/// Generic value parsers shared across the project. Lives in `ContainerPersistence`
/// so both higher-level CLI parsers and the persistence layer can reuse the same
/// canonical implementations.
public enum Parsers {
    /// Parse a boolean string accepting "true"/"t"/"false"/"f" (case-insensitive).
    /// Returns nil if the input matches none.
    public static func parseBool(string: String) -> Bool? {
        switch string.lowercased() {
        case "true", "t": return true
        case "false", "f": return false
        default: return nil
        }
    }
}
