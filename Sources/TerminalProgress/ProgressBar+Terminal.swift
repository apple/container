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

import ContainerizationOS
import Foundation

enum EscapeSequence {
    static let hideCursor = "\u{001B}[?25l"
    static let showCursor = "\u{001B}[?25h"
    static let moveUp = "\u{001B}[1A"
}

extension ProgressBar {
    private var terminalWidth: Int {
        guard
            let terminalHandle = term,
            let terminal = try? Terminal(descriptor: terminalHandle.fileDescriptor)
        else {
            return 0
        }

        let terminalWidth = (try? Int(terminal.size.width)) ?? 0
        return terminalWidth
    }

    /// Clears the progress bar and resets the cursor.
    public func clearAndResetCursor() {
        clear()
        resetCursor()
    }

    /// Clears the progress bar.
    public func clear() {
        displayText("")
    }

    /// Resets the cursor.
    public func resetCursor() {
        display(EscapeSequence.showCursor)
    }

    func display(_ text: String) {
        guard let term else {
            return
        }
        termQueue.sync {
            try? term.write(contentsOf: Data(text.utf8))
            try? term.synchronize()
        }
    }

    func displayText(_ text: String, terminating: String = "\r") {
        var text = text

        // Clears previously printed characters if the new string is shorter.
        text += String(repeating: " ", count: max(printedWidth - text.count, 0))
        printedWidth = text.count
        state.output = text

        // Clears previously printed lines.
        var lines = ""
        if terminating.hasSuffix("\r") && terminalWidth > 0 {
            let lineCount = (text.count - 1) / terminalWidth
            for _ in 0..<lineCount {
                lines += EscapeSequence.moveUp
            }
        }

        text = "\(text)\(terminating)\(lines)"
        display(text)
    }
}
