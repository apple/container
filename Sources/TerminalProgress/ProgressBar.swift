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

import Foundation
import SendableProperty

/// A progress bar that updates itself as tasks are completed.
public final class ProgressBar: Sendable {
    let config: ProgressConfig
    // `@SendableProperty` adds `_state: Synchronized<State>`, which can be updated inside a lock using `_state.withLock()`.
    @SendableProperty
    var state = State()
    @SendableProperty
    var printedWidth = 0
    let term: FileHandle?
    let termQueue = DispatchQueue(label: "com.apple.container.ProgressBar")
    private let standardError = StandardError()

    /// Returns `true` if the progress bar has finished.
    public var isFinished: Bool {
        state.finished
    }

    /// Creates a new progress bar.
    /// - Parameter config: The configuration for the progress bar.
    public init(config: ProgressConfig) {
        self.config = config
        term = isatty(config.terminal.fileDescriptor) == 1 ? config.terminal : nil
        state = State(
            description: config.initialDescription, itemsName: config.initialItemsName, totalTasks: config.initialTotalTasks,
            totalItems: config.initialTotalItems,
            totalSize: config.initialTotalSize)
        display(EscapeSequence.hideCursor)
    }

    deinit {
        clear()
    }

    /// Allows resetting the progress state.
    public func reset() {
        state = State(description: config.initialDescription)
    }

    /// Allows resetting the progress state of the current task.
    public func resetCurrentTask() {
        state = State(description: state.description, itemsName: state.itemsName, tasks: state.tasks, totalTasks: state.totalTasks, startTime: state.startTime)
    }

    private func printFullDescription() {
        if state.subDescription != "" {
            standardError.write("\(state.description) \(state.subDescription)")
        } else {
            standardError.write(state.description)
        }
    }

    /// Updates the description of the progress bar and increments the tasks by one.
    /// - Parameter description: The description of the action being performed.
    public func set(description: String) {
        resetCurrentTask()

        state.description = description
        state.subDescription = ""
        if config.disableProgressUpdates {
            printFullDescription()
        }

        state.tasks += 1
    }

    /// Updates the additional description of the progress bar.
    /// - Parameter subDescription: The additional description of the action being performed.
    public func set(subDescription: String) {
        resetCurrentTask()

        state.subDescription = subDescription
        if config.disableProgressUpdates {
            printFullDescription()
        }
    }

    private func start(intervalSeconds: TimeInterval) async {
        if config.disableProgressUpdates && !state.description.isEmpty {
            printFullDescription()
        }

        while !state.finished {
            let intervalNanoseconds = UInt64(intervalSeconds * 1_000_000_000)
            render()
            state.iteration += 1
            if (try? await Task.sleep(nanoseconds: intervalNanoseconds)) == nil {
                return
            }
        }
    }

    /// Starts an animation of the progress bar.
    /// - Parameter intervalSeconds: The time interval between updates in seconds.
    public func start(intervalSeconds: TimeInterval = 0.04) {
        Task(priority: .utility) {
            await start(intervalSeconds: intervalSeconds)
        }
    }

    /// Finishes the progress bar.
    public func finish() {
        guard !state.finished else {
            return
        }

        state.finished = true

        // The last render.
        render(force: true)

        if !config.disableProgressUpdates && !config.clearOnFinish {
            displayText(state.output, terminating: "\n")
        }

        if config.clearOnFinish {
            clearAndResetCursor()
        } else {
            resetCursor()
        }
        // Allow printed output to flush.
        usleep(100_000)
    }
}

extension ProgressBar {
    private func secondsSinceStart() -> Int {
        let timeDifferenceNanoseconds = DispatchTime.now().uptimeNanoseconds - state.startTime.uptimeNanoseconds
        let timeDifferenceSeconds = Int(floor(Double(timeDifferenceNanoseconds) / 1_000_000_000))
        return timeDifferenceSeconds
    }

    func render(force: Bool = false) {
        guard term != nil && !config.disableProgressUpdates && (force || !state.finished) else {
            return
        }
        let output = draw()
        displayText(output)
    }

    func draw() -> String {
        var components = [String]()
        if config.showSpinner && !config.showProgressBar {
            if !state.finished {
                let spinnerIcon = config.theme.getSpinnerIcon(state.iteration)
                components.append("\(spinnerIcon)")
            } else {
                components.append("\(config.theme.done)")
            }
        }

        if config.showTasks, let totalTasks = state.totalTasks {
            let tasks = min(state.tasks, totalTasks)
            components.append("[\(tasks)/\(totalTasks)]")
        }

        if config.showDescription && !state.description.isEmpty {
            components.append("\(state.description)")
            if !state.subDescription.isEmpty {
                components.append("\(state.subDescription)")
            }
        }

        let allowProgress = !config.ignoreSmallSize || state.totalSize == nil || state.totalSize! > Int64(1024 * 1024)

        let value = state.totalSize != nil ? state.size : Int64(state.items)
        let total = state.totalSize ?? Int64(state.totalItems ?? 0)

        if config.showPercent && total > 0 && allowProgress {
            components.append("\(state.finished ? "100%" : state.percent)")
        }

        if config.showProgressBar, total > 0, allowProgress {
            let usedWidth = components.joined(separator: " ").count + 45 /* the maximum number of characters we may need */
            let remainingWidth = max(config.width - usedWidth, 1 /* the minimum width of a progress bar */)
            let barLength = state.finished ? remainingWidth : Int(Int64(remainingWidth) * value / total)
            let barPaddingLength = remainingWidth - barLength
            let bar = "\(String(repeating: config.theme.bar, count: barLength))\(String(repeating: " ", count: barPaddingLength))"
            components.append("|\(bar)|")
        }

        var additionalComponents = [String]()

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

        if state.size > 0 && allowProgress {
            if state.finished {
                if config.showSize {
                    if let totalSize = state.totalSize {
                        var formattedTotalSize = totalSize.formattedSize()
                        formattedTotalSize = adjustFormattedSize(formattedTotalSize)
                        additionalComponents.append(formattedTotalSize)
                    }
                }
            } else {
                var formattedCombinedSize = ""
                if config.showSize {
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

                var formattedSpeed = ""
                if config.showSpeed {
                    formattedSpeed = "\(state.sizeSpeed ?? state.averageSizeSpeed)"
                    formattedSpeed = adjustFormattedSize(formattedSpeed)
                }

                if config.showSize && config.showSpeed {
                    additionalComponents.append(formattedCombinedSize)
                    additionalComponents.append(formattedSpeed)
                } else if config.showSize {
                    additionalComponents.append(formattedCombinedSize)
                } else if config.showSpeed {
                    additionalComponents.append(formattedSpeed)
                }
            }
        }

        if additionalComponents.count > 0 {
            let joinedAdditionalComponents = additionalComponents.joined(separator: ", ")
            components.append("(\(joinedAdditionalComponents))")
        }

        if config.showTime {
            let timeDifferenceSeconds = secondsSinceStart()
            let formattedTime = timeDifferenceSeconds.formattedTime()
            components.append("[\(formattedTime)]")
        }

        return components.joined(separator: " ")
    }

    private func adjustFormattedSize(_ size: String) -> String {
        // Ensure we always have one digit after the decimal point to prevent flickering.
        let zero = Int64(0).formattedSize()
        guard !size.contains("."), let first = size.first, first.isNumber || !size.contains(zero) else {
            return size
        }
        var size = size
        for unit in ["MB", "GB", "TB"] {
            size = size.replacingOccurrences(of: " \(unit)", with: ".0 \(unit)")
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
}
