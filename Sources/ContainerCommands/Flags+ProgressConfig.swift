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
import Foundation
import TerminalProgress

extension Flags.Progress {
    /// Resolves `.auto` into `.ansi` or `.plain` based on whether stderr is a TTY.
    private func resolvedProgress() -> ProgressType {
        switch progress {
        case .auto:
            return isatty(FileHandle.standardError.fileDescriptor) == 1 ? .ansi : .plain
        case .none, .ansi, .plain, .color:
            return progress
        }
    }

    /// Creates a `ProgressConfig` based on the selected progress type.
    ///
    /// For `.none`, progress updates are disabled. For `.ansi`, the given parameters
    /// are used as-is. For `.plain`, ANSI-incompatible features (spinner, clear on finish)
    /// are disabled and the output mode is set to `.plain`. For `.color`, behavior matches
    /// `.ansi` but the output mode is set to `.color` to enable color-coded output.
    /// For `.auto`, the type is resolved by checking whether stderr is a TTY.
    func makeConfig(
        description: String = "",
        itemsName: String = "it",
        showTasks: Bool = false,
        showItems: Bool = false,
        showSpeed: Bool = true,
        ignoreSmallSize: Bool = false,
        totalTasks: Int? = nil
    ) throws -> ProgressConfig {
        let resolved = resolvedProgress()
        switch resolved {
        case .none:
            return try ProgressConfig(disableProgressUpdates: true)
        case .ansi, .plain, .color:
            let isPlain = resolved == .plain
            let outputMode: ProgressConfig.OutputMode
            switch resolved {
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
        case .auto:
            fatalError("unreachable: .auto should have been resolved")
        }
    }
}
