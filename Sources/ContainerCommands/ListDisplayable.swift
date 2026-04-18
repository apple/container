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

/// A type that can be rendered as a table row or quiet-mode output.
///
/// Conformers provide the column headers, row values, and a primary identifier
/// for quiet mode. JSON encoding is handled separately by each command using
/// its own data model.
public protocol ListDisplayable {
    /// Column headers for table output (e.g., `["ID", "IMAGE", "STATE"]`).
    static var tableHeader: [String] { get }
    /// The values for each column, matching the order of ``tableHeader``.
    var tableRow: [String] { get }
    /// The primary identifier shown in `--quiet` mode (typically ID or name).
    var quietValue: String { get }
}
