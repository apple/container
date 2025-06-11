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

/// A theme for progress bar.
public protocol ProgressTheme: Sendable {
    /// The icons used to represent a spinner.
    var spinner: [String] { get }
    /// The icon used to represent a progress bar.
    var bar: String { get }
    /// The icon used to indicate that a progress bar finished.
    var done: String { get }
}

public struct DefaultProgressTheme: ProgressTheme {
    public let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    public let bar = "█"
    public let done = "✔"
}

extension ProgressTheme {
    func getSpinnerIcon(_ iteration: Int) -> String {
        spinner[iteration % spinner.count]
    }
}
