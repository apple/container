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
    static let clearLine = "\u{001B}[2K"
    static let moveUp = "\u{001B}[1A"
}

extension ProgressBar {
    /// Clears the progress bar and resets the cursor.
    static public func clearAndResetCursor() {
        ProgressBar.clear()
        ProgressBar.resetCursor()
    }

    /// Clears the progress bar.
    static public func clear() {
        ProgressBar.display(EscapeSequence.clearLine)
    }

    /// Resets the cursor.
    static public func resetCursor() {
        ProgressBar.display(EscapeSequence.showCursor)
    }

    static func getTerminal() -> FileHandle? {
        let standardError = FileHandle.standardError
        let fd = standardError.fileDescriptor
        let isATTY = isatty(fd)
        return isATTY == 1 ? standardError : nil
    }

    static func display(_ text: String) {
        guard let term else {
            return
        }
        termQueue.sync {
            try? term.write(contentsOf: Data(text.utf8))
            try? term.synchronize()
        }
    }

    func displayText(_ text: String, terminating: String = "\r") {
        guard
            let termimalHandle = ProgressBar.term,
            let terminal = try? Terminal(descriptor: termimalHandle.fileDescriptor)
        else {
            return
        }

        var text = text

        // Clears previously printed characters if the new string is shorter.
        text += String(repeating: " ", count: max(state.output.count - text.count, 0))
        state.output = text

        // Clears previously printed lines.
        let terminalWidth = (try? Int(terminal.size.width)) ?? 0
        var lines = ""
        if terminalWidth > 0 {
            let lineCount = (text.count - 1) / terminalWidth
            for _ in 0..<lineCount {
                lines += EscapeSequence.moveUp
            }
        }

        text = "\(text)\(terminating)\(lines)"
        ProgressBar.display(text)
    }
}
