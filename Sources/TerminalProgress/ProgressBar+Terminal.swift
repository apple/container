//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
    static let clearToEndOfLine = "\u{001B}[K"

    // Color codes
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let cyan = "\u{001B}[36m"

    /// Wraps text in an ANSI color code with a reset suffix.
    static func colored(_ text: String, _ code: String) -> String {
        "\(code)\(text)\(reset)"
    }
}

extension ProgressBar {
    var termWidth: Int {
        guard
            let terminalHandle = term,
            let terminal = try? Terminal(descriptor: terminalHandle.fileDescriptor)
        else {
            return 0
        }

        return (try? Int(terminal.size.width)) ?? 0
    }

    /// Clears the progress bar and resets the cursor.
    public func clearAndResetCursor() {
        state.withLock { s in
            clear(state: &s)
            switch config.outputMode {
            case .ansi, .color:
                resetCursor()
            case .plain:
                break
            }
        }
    }

    /// Clears the progress bar.
    public func clear() {
        state.withLock { s in
            clear(state: &s)
        }
    }

    /// Clears the progress bar (caller must hold state lock).
    func clear(state: inout State) {
        displayText("", state: &state)
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
        state.withLock { s in
            displayText(text, state: &s, terminating: terminating)
        }
    }

    func displayText(_ text: String, state: inout State, terminating: String = "\r") {
        state.output = text

        switch config.outputMode {
        case .plain:
            guard !text.isEmpty else { return }
            display("\(text)\(terminating)")
        case .ansi, .color:
            // Clears previously printed lines.
            var lines = ""
            if terminating.hasSuffix("\r") && termWidth > 0 {
                let textLength = config.outputMode == .color ? text.visibleLength : text.count
                let lineCount = (textLength - 1) / termWidth
                for _ in 0..<lineCount {
                    lines += EscapeSequence.moveUp
                }
            }

            let output = "\(text)\(EscapeSequence.clearToEndOfLine)\(terminating)\(lines)"
            display(output)
        }
    }
}

extension String {
    /// The visible character count, excluding ANSI escape sequences.
    var visibleLength: Int {
        replacingOccurrences(of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression).count
    }
}
