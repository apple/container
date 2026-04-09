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

import ContainerAPIClient
import TerminalProgress

extension Flags.Progress {
    /// Creates a `ProgressConfig` based on the selected progress type.
    ///
    /// For `.none`, progress updates are disabled. For `.ansi`, the given parameters
    /// are used as-is. For `.plain`, ANSI-incompatible features (spinner, clear on finish)
    /// are disabled and the output mode is set to `.plain`. For `.color`, behavior matches
    /// `.ansi` but the output mode is set to `.color` to enable color-coded output.
    func makeConfig(
        description: String = "",
        itemsName: String = "it",
        showTasks: Bool = false,
        showItems: Bool = false,
        showSpeed: Bool = true,
        ignoreSmallSize: Bool = false,
        totalTasks: Int? = nil
    ) throws -> ProgressConfig {
        switch progress {
        case .none:
            return try ProgressConfig(disableProgressUpdates: true)
        case .ansi, .plain, .color:
            let isPlain = progress == .plain
            let outputMode: ProgressConfig.OutputMode
            switch progress {
            case .plain: outputMode = .plain
            case .color: outputMode = .color
            default: outputMode = .ansi
            }
            return try ProgressConfig(
                description: description,
                itemsName: itemsName,
                showSpinner: !isPlain,
                showTasks: showTasks,
                showItems: showItems,
                showSpeed: showSpeed,
                ignoreSmallSize: ignoreSmallSize,
                totalTasks: totalTasks,
                clearOnFinish: !isPlain,
                outputMode: outputMode
            )
        }
    }
}
