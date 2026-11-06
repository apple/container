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

extension ProgressBar {
    /// Makes sure the terminal cursor is visible again when the process exits,
    /// including when it is terminated by SIGINT or SIGTERM.
    ///
    /// A progress bar hides the cursor while it renders, so a process that is
    /// killed mid-render would otherwise leave the user's terminal without one.
    /// Call this once at the start of `main()`. Handlers do not survive `exec`,
    /// so a plugin binary must call it itself.
    public static func restoreCursorAtExit() {
        let signalHandler: @convention(c) (Int32) -> Void = { signal in
            exit(signal + 128)
        }
        // Termination by Ctrl+C.
        signal(SIGINT, signalHandler)
        // Termination using `kill`.
        signal(SIGTERM, signalHandler)
        // Normal and explicit exit.
        atexit {
            if let progressConfig = try? ProgressConfig() {
                let progressBar = ProgressBar(config: progressConfig)
                progressBar.resetCursor()
            }
        }
    }
}
