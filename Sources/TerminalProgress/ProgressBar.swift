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

import Foundation
import Synchronization

/// A progress bar that updates itself as tasks are completed.
public final class ProgressBar: Sendable {
    let config: ProgressConfig
    let state: Mutex<State>
    let term: FileHandle?
    let termQueue = DispatchQueue(label: "com.apple.container.ProgressBar")

    /// Returns `true` if the progress bar has finished.
    public var isFinished: Bool {
        state.withLock { $0.finished }
    }

    /// Creates a new progress bar.
    /// - Parameter config: The configuration for the progress bar.
    public init(config: ProgressConfig) {
        self.config = config
        term = isatty(config.terminal.fileDescriptor) == 1 ? config.terminal : nil
        let state = State(
            description: config.initialDescription, itemsName: config.initialItemsName, totalTasks: config.initialTotalTasks,
            totalItems: config.initialTotalItems,
            totalSize: config.initialTotalSize)
        self.state = Mutex(state)
        display(EscapeSequence.hideCursor)
    }

    /// Allows resetting the progress state.
    public func reset() {
        state.withLock {
            $0 = State(description: config.initialDescription)
        }
    }

    /// Allows resetting the progress state of the current task.
    public func resetCurrentTask() {
        state.withLock {
            $0 = State(description: $0.description, itemsName: $0.itemsName, tasks: $0.tasks, totalTasks: $0.totalTasks, startTime: $0.startTime)
        }
    }

    /// Updates the description of the progress bar and increments the tasks by one.
    /// - Parameter description: The description of the action being performed.
    public func set(description: String) {
        resetCurrentTask()

        state.withLock {
            $0.description = description
            $0.subDescription = ""
            $0.tasks += 1
        }
    }

    /// Updates the additional description of the progress bar.
    /// - Parameter subDescription: The additional description of the action being performed.
    public func set(subDescription: String) {
        resetCurrentTask()

        state.withLock { $0.subDescription = subDescription }
    }

    private func start(intervalSeconds: TimeInterval) async {
        while true {
            let done = state.withLock { s -> Bool in
                guard !s.finished else {
                    return true
                }
                render(state: &s)
                s.iteration += 1
                return false
            }

            if done {
                return
            }

            let intervalNanoseconds = UInt64(intervalSeconds * 1_000_000_000)
            guard (try? await Task.sleep(nanoseconds: intervalNanoseconds)) != nil else {
                return
            }
        }
    }

    /// Starts an animation of the progress bar.
    /// - Parameter intervalSeconds: The time interval between updates in seconds.
    public func start(intervalSeconds: TimeInterval = 0.04) {
        state.withLock {
            if $0.renderTask != nil {
                return
            }
            $0.renderTask = Task(priority: .utility) {
                await start(intervalSeconds: intervalSeconds)
            }
        }
    }

    /// Finishes the progress bar.
    /// - Parameter clearScreen: If true, clears the progress bar from the screen.
    public func finish(clearScreen: Bool = false) {
        state.withLock { s in
            guard !s.finished else { return }

            s.finished = true
            s.renderTask?.cancel()

            let shouldClear = clearScreen || config.clearOnFinish
            if !config.disableProgressUpdates && !shouldClear {
                let output = draw(state: s)
                displayText(output, state: &s, terminating: "\n")
            }

            if shouldClear {
                clear(state: &s)
            }
            resetCursor()
        }
    }
}

extension ProgressBar {
    private func secondsSinceStart(from startTime: DispatchTime) -> Int {
        let timeDifferenceNanoseconds = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let timeDifferenceSeconds = Int(floor(Double(timeDifferenceNanoseconds) / 1_000_000_000))
        return timeDifferenceSeconds
    }

    func render(force: Bool = false) {
        guard term != nil && !config.disableProgressUpdates else {
            return
        }
        state.withLock { s in
            render(state: &s, force: force)
        }
    }

    func render(state: inout State, force: Bool = false) {
        guard term != nil && !config.disableProgressUpdates else {
            return
        }
        guard force || !state.finished else {
            return
        }
        let output = draw(state: state)
        displayText(output, state: &state)
    }

    /// Detail levels for progressive truncation.
    enum DetailLevel: Int, CaseIterable {
        case full = 0  // Everything shown
        case noSpeed  // Drop speed from parens
        case noSize  // Drop size from parens
        case noParens  // Drop parens entirely (items, size, speed)
        case noTime  // Drop time
        case noDescription  // Drop description/subdescription
        case minimal  // Just spinner, tasks, percent
    }

    func draw(state: State) -> String {
        let width = termWidth
        // If no terminal or width unknown, use full detail
        guard width > 0 else {
            return draw(state: state, detail: .full)
        }

        // Add a small buffer to prevent wrapping issues during resize
        let bufferChars = 4
        let targetWidth = max(1, width - bufferChars)

        for detail in DetailLevel.allCases {
            let output = draw(state: state, detail: detail)
            if output.count <= targetWidth {
                return output
            }
        }

        return draw(state: state, detail: .minimal)
    }

    func draw(state: State, detail: DetailLevel) -> String {
        var components = [String]()

        // Spinner - always shown if configured (unless using progress bar)
        if config.showSpinner && !config.showProgressBar {
            if !state.finished {
                let spinnerIcon = config.theme.getSpinnerIcon(state.iteration)
                components.append("\(spinnerIcon)")
            } else {
                components.append("\(config.theme.done)")
            }
        }

        // Tasks [x/y] - always shown if configured
        if config.showTasks, let totalTasks = state.totalTasks {
            let tasks = min(state.tasks, totalTasks)
            components.append("[\(tasks)/\(totalTasks)]")
        }

        // Description - dropped at noDescription level
        if detail.rawValue < DetailLevel.noDescription.rawValue {
            if config.showDescription && !state.description.isEmpty {
                components.append("\(state.description)")
                if !state.subDescription.isEmpty {
                    components.append("\(state.subDescription)")
                }
            }
        }

        let allowProgress = !config.ignoreSmallSize || state.totalSize == nil || state.totalSize! > Int64(1024 * 1024)
        let value = state.totalSize != nil ? state.size : Int64(state.items)
        let total = state.totalSize ?? Int64(state.totalItems ?? 0)

        // Percent - always shown if configured
        if config.showPercent && total > 0 && allowProgress {
            components.append("\(state.finished ? "100%" : state.percent)")
        }

        // Progress bar - always shown if configured
        if config.showProgressBar, total > 0, allowProgress {
            let usedWidth = components.joined(separator: " ").count + 45
            let remainingWidth = max(config.width - usedWidth, 1)
            let barLength = state.finished ? remainingWidth : Int(Int64(remainingWidth) * value / total)
            let barPaddingLength = remainingWidth - barLength
            let bar = "\(String(repeating: config.theme.bar, count: barLength))\(String(repeating: " ", count: barPaddingLength))"
            components.append("|\(bar)|")
        }

        // Additional components in parens - progressively dropped
        if detail.rawValue < DetailLevel.noParens.rawValue {
            var additionalComponents = [String]()

            // Items - dropped at noParens level
            if config.showItems, state.items > 0 {
                var itemsName = ""
                if !state.itemsName.isEmpty {
                    itemsName = " \(state.itemsName)"
                }
                if state.finished {
                    if let totalItems = state.totalItems {
                        additionalComponents.append("\(totalItems.formattedNumber())\(itemsName)")
                    }
                } else {
                    if let totalItems = state.totalItems {
                        additionalComponents.append("\(state.items.formattedNumber()) of \(totalItems.formattedNumber())\(itemsName)")
                    } else {
                        additionalComponents.append("\(state.items.formattedNumber())\(itemsName)")
                    }
                }
            }

            // Size and speed - progressively dropped
            if state.size > 0 && allowProgress {
                if state.finished {
                    // Size - dropped at noSize level
                    if detail.rawValue < DetailLevel.noSize.rawValue {
                        if config.showSize {
                            if let totalSize = state.totalSize {
                                var formattedTotalSize = totalSize.formattedSize()
                                formattedTotalSize = adjustFormattedSize(formattedTotalSize)
                                additionalComponents.append(formattedTotalSize)
                            }
                        }
                    }
                } else {
                    // Size - dropped at noSize level
                    var formattedCombinedSize = ""
                    if detail.rawValue < DetailLevel.noSize.rawValue && config.showSize {
                        var formattedSize = state.size.formattedSize()
                        formattedSize = adjustFormattedSize(formattedSize)
                        if let totalSize = state.totalSize {
                            var formattedTotalSize = totalSize.formattedSize()
                            formattedTotalSize = adjustFormattedSize(formattedTotalSize)
                            formattedCombinedSize = combineSize(size: formattedSize, totalSize: formattedTotalSize)
                        } else {
                            formattedCombinedSize = formattedSize
                        }
                    }

                    // Speed - dropped at noSpeed level
                    var formattedSpeed = ""
                    if detail.rawValue < DetailLevel.noSpeed.rawValue && config.showSpeed {
                        formattedSpeed = "\(state.sizeSpeed ?? state.averageSizeSpeed)"
                        formattedSpeed = adjustFormattedSize(formattedSpeed)
                    }

                    if !formattedCombinedSize.isEmpty && !formattedSpeed.isEmpty {
                        additionalComponents.append(formattedCombinedSize)
                        additionalComponents.append(formattedSpeed)
                    } else if !formattedCombinedSize.isEmpty {
                        additionalComponents.append(formattedCombinedSize)
                    } else if !formattedSpeed.isEmpty {
                        additionalComponents.append(formattedSpeed)
                    }
                }
            }

            if additionalComponents.count > 0 {
                let joinedAdditionalComponents = additionalComponents.joined(separator: ", ")
                components.append("(\(joinedAdditionalComponents))")
            }
        }

        // Time - dropped at noTime level
        if detail.rawValue < DetailLevel.noTime.rawValue && config.showTime {
            let timeDifferenceSeconds = secondsSinceStart(from: state.startTime)
            let formattedTime = timeDifferenceSeconds.formattedTime()
            components.append("[\(formattedTime)]")
        }

        return components.joined(separator: " ")
    }

    private func adjustFormattedSize(_ size: String) -> String {
        // Ensure we always have one digit after the decimal point to prevent flickering.
        let zero = Int64(0).formattedSize()
        let decimalSep = Locale.current.decimalSeparator ?? "."
        guard !size.contains(decimalSep), let first = size.first, first.isNumber || !size.contains(zero) else {
            return size
        }
        var size = size
        for unit in ["MB", "GB", "TB"] {
            size = size.replacingOccurrences(of: " \(unit)", with: "\(decimalSep)0 \(unit)")
        }
        return size
    }

    private func combineSize(size: String, totalSize: String) -> String {
        let sizeComponents = size.split(separator: " ", maxSplits: 1)
        let totalSizeComponents = totalSize.split(separator: " ", maxSplits: 1)
        guard sizeComponents.count == 2, totalSizeComponents.count == 2 else {
            return "\(size)/\(totalSize)"
        }
        let sizeNumber = sizeComponents[0]
        let sizeUnit = sizeComponents[1]
        let totalSizeNumber = totalSizeComponents[0]
        let totalSizeUnit = totalSizeComponents[1]
        guard sizeUnit == totalSizeUnit else {
            return "\(size)/\(totalSize)"
        }
        return "\(sizeNumber)/\(totalSizeNumber) \(totalSizeUnit)"
    }

    func draw() -> String {
        state.withLock { draw(state: $0) }
    }
}
