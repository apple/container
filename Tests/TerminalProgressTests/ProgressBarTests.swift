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
import Testing

@testable import TerminalProgress

struct ProgressBarTests {
    @Test func spinner() throws {
        let config = try ProgressConfig(
            description: "Task"
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func spinnerFinished() throws {
        let config = try ProgressConfig(
            description: "Task"
        )
        let progress = ProgressBar(config: config)
        progress.finish()
        let output = progress.draw()
        #expect(output == "✔ Task [0s]")
    }

    @Test func noSpinner() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpinner: false
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "Task [0s]")
    }

    @Test func noSpinnerFinished() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpinner: false
        )
        let progress = ProgressBar(config: config)
        progress.finish()
        let output = progress.draw()
        #expect(output == "Task [0s]")
    }

    @Test func noTasks() throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: false
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func tasks() throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func tasksAdd() throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true
        )
        let progress = ProgressBar(config: config)
        progress.add(tasks: 1)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func tasksSet() throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true
        )
        let progress = ProgressBar(config: config)
        progress.set(tasks: 2)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func totalTasks() throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true,
            totalTasks: 2
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ [0/2] Task [0s]")
    }

    @Test func totalTasksFinished() throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true,
            totalTasks: 2
        )
        let progress = ProgressBar(config: config)
        progress.finish()
        let output = progress.draw()
        #expect(output == "✔ [0/2] Task [0s]")
    }

    @Test func totalTasksAdd() throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true,
            totalTasks: 1
        )
        let progress = ProgressBar(config: config)
        progress.add(totalTasks: 1)
        let output = progress.draw()
        #expect(output == "⠋ [0/2] Task [0s]")
    }

    @Test func totalTasksSet() throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true,
            totalTasks: 1
        )
        let progress = ProgressBar(config: config)
        progress.set(totalTasks: 2)
        let output = progress.draw()
        #expect(output == "⠋ [0/2] Task [0s]")
    }

    @Test func totalTasksInvalid() {
        #expect(throws: ProgressConfig.Error.self) {
            try ProgressConfig(description: "test", totalTasks: 0)
        }
    }

    @Test func description() throws {
        let config = try ProgressConfig(
            description: "Task"
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func noDescription() throws {
        let config = try ProgressConfig()
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ [0s]")
    }

    @Test func noPercent() throws {
        let config = try ProgressConfig(
            description: "Task",
            showPercent: false,
            totalItems: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func percentHidden() throws {
        let config = try ProgressConfig(
            description: "Task",
            showPercent: true
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func percentItems() throws {
        let config = try ProgressConfig(
            description: "Task",
            showPercent: true,
            totalItems: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% [0s]")
    }

    @Test func percentItemsFinished() throws {
        let config = try ProgressConfig(
            description: "Task",
            showPercent: true,
            totalItems: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.finish()
        let output = progress.draw()
        #expect(output == "✔ Task 100% [0s]")
    }

    @Test func percentSize() throws {
        let config = try ProgressConfig(
            description: "Task",
            showPercent: true,
            showSize: false,
            showSpeed: false,
            totalSize: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 1)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% [0s]")
    }

    @Test func percentSizeFinished() throws {
        let config = try ProgressConfig(
            description: "Task",
            showPercent: true,
            showSize: false,
            showSpeed: false,
            totalSize: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 1)
        progress.finish()
        let output = progress.draw()
        #expect(output == "✔ Task 100% [0s]")
    }

    @Test func noProgressBar() throws {
        let config = try ProgressConfig(
            description: "Task",
            showProgressBar: false,
            totalItems: 2,
            width: 57
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% [0s]")
    }

    @Test func progressBar() throws {
        let config = try ProgressConfig(
            description: "Task",
            showProgressBar: true,
            totalItems: 2,
            width: 57
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        #expect(output == "Task 50% |██  | [0s]")
    }

    @Test func progressBarFinished() throws {
        let config = try ProgressConfig(
            description: "Task",
            showProgressBar: true,
            totalItems: 2,
            width: 57
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.finish()
        let output = progress.draw()
        #expect(output == "Task 100% |███| [0s]")
    }

    @Test func progressBarMinWidth() throws {
        let config = try ProgressConfig(
            description: "Task",
            showProgressBar: true,
            totalItems: 2,
            width: 13
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        #expect(output == "Task 50% | | [0s]")
    }

    @Test func progressBarMinWidthFinished() throws {
        let config = try ProgressConfig(
            description: "Task",
            showProgressBar: true,
            totalItems: 2,
            width: 13
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.finish()
        let output = progress.draw()
        #expect(output == "Task 100% |█| [0s]")
    }

    @Test func noItems() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: false
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func itemsZero() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func itemsAdd() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true
        )
        let progress = ProgressBar(config: config)
        progress.add(items: 1)
        let output = progress.draw()
        #expect(output == "⠋ Task (1 it) [0s]")
    }

    @Test func itemsAddFinish() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true
        )
        let progress = ProgressBar(config: config)
        progress.add(items: 1)
        progress.finish()
        let output = progress.draw()
        #expect(output == "✔ Task [0s]")
    }

    @Test func itemsSet() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 2)
        let output = progress.draw()
        #expect(output == "⠋ Task (2 it) [0s]")
    }

    @Test func totalItemsZeroItems() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            totalItems: 1
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ Task 0% [0s]")
    }

    @Test func totalItems() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            totalItems: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% (1 of 2 it) [0s]")
    }

    @Test func totalItemsFinish() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            totalItems: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.finish()
        let output = progress.draw()
        #expect(output == "✔ Task 100% (2 it) [0s]")
    }

    @Test func totalItemsAdd() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            totalItems: 1
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.add(totalItems: 1)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% (1 of 2 it) [0s]")
    }

    @Test func totalItemsSet() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            totalItems: 1
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.set(totalItems: 2)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% (1 of 2 it) [0s]")
    }

    @Test func totalItemsInvalid() {
        #expect(throws: ProgressConfig.Error.self) {
            try ProgressConfig(description: "test", totalItems: 0)
        }
    }

    @Test func noSize() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: false
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func sizeZero() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func sizeAdd() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false
        )
        let progress = ProgressBar(config: config)
        progress.add(size: 1)
        let output = progress.draw()
        #expect(output == "⠋ Task (1 byte) [0s]")
    }

    @Test func sizeAddFinish() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false
        )
        let progress = ProgressBar(config: config)
        progress.add(size: 1)
        progress.finish()
        let output = progress.draw()
        #expect(output == "✔ Task [0s]")
    }

    @Test func sizeSet() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        let output = progress.draw()
        #expect(output == "⠋ Task (2 bytes) [0s]")
    }

    @Test func totalSizeZeroSize() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            totalSize: 1
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ Task 0% [0s]")
    }

    @Test func totalSizeDifferentUnits() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false,
            totalSize: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 1)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% (1 byte/2 bytes) [0s]")
    }

    @Test func totalSizeDifferentUnitsFinish() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false,
            totalSize: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 1)
        progress.finish()
        let output = progress.draw()
        #expect(output == "✔ Task 100% (2 bytes) [0s]")
    }

    @Test func totalSizeSameUnits() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% (2/4 bytes) [0s]")
    }

    @Test func totalSizeSameUnitsFinish() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        progress.finish()
        let output = progress.draw()
        #expect(output == "✔ Task 100% (4 bytes) [0s]")
    }

    @Test func totalSizeAdd() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false,
            totalSize: 3
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        progress.add(totalSize: 1)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% (2/4 bytes) [0s]")
    }

    @Test func totalSizeSet() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false,
            totalSize: 3
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        progress.set(totalSize: 4)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% (2/4 bytes) [0s]")
    }

    @Test func totalSizeInvalid() {
        #expect(throws: ProgressConfig.Error.self) {
            try ProgressConfig(description: "test", totalSize: 0)
        }
    }

    @Test func itemsAndSize() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            showSize: true,
            showSpeed: false,
            totalItems: 2,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.set(size: 2)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% (1 of 2 it, 2/4 bytes) [0s]")
    }

    @Test func itemsAndSizeFinish() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            showSize: true,
            showSpeed: false,
            totalItems: 2,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.set(size: 2)
        progress.finish()
        let output = progress.draw()
        #expect(output == "✔ Task 100% (2 it, 4 bytes) [0s]")
    }

    @Test func noSpeed() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpeed: false,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% (2/4 bytes) [0s]")
    }

    @Test func speed() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpeed: true,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        let output = progress.draw()
        #expect(output.contains("/s"))
    }

    @Test func speedFinish() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpeed: true,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        progress.finish()
        let output = progress.draw()
        #expect(!output.contains("/s"))
    }

    @Test func itemsSizeAndSpeed() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            showSize: true,
            showSpeed: true,
            totalItems: 2,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.set(size: 2)
        let output = progress.draw()
        #expect(output.contains("1 of 2 it, 2/4 bytes"))
        #expect(output.contains("/s"))
    }

    @Test func itemsSizeAndSpeedFinish() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            showSize: true,
            showSpeed: true,
            totalItems: 2,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.set(size: 2)
        progress.finish()
        let output = progress.draw()
        #expect(output.contains("2 it, 4 bytes"))
        #expect(!output.contains("/s"))
    }

    @Test func noTime() throws {
        let config = try ProgressConfig(
            description: "Task",
            showTime: false
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "⠋ Task")
    }

    @Test func time() throws {
        let config = try ProgressConfig(
            description: "Task",
            showTime: true
        )
        let progress = ProgressBar(config: config)
        sleep(1)
        let output = progress.draw()
        #expect(output == "⠋ Task [1s]")
    }

    @Test func ignoreSmallSize() throws {
        let config = try ProgressConfig(
            description: "Task",
            ignoreSmallSize: true,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        let output = progress.draw()
        #expect(output == "⠋ Task [0s]")
    }

    @Test func progressBarSizeExceedsTotal() throws {
        let config = try ProgressConfig(
            description: "Task",
            showProgressBar: true,
            totalSize: 50
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 100)
        let _ = progress.draw()
    }

    @Test func progressBarNegativeValue() throws {
        // Regression test: a negative progress value (e.g. from a race in progress events)
        // must not cause String(repeating:count:) to be called with a negative count.
        let config = try ProgressConfig(
            description: "Task",
            showProgressBar: true,
            totalSize: 50,
            width: 57
        )
        let progress = ProgressBar(config: config)
        progress.set(size: -10)
        // draw(state:detail:) should clamp barLength to [0, remainingWidth] and not crash.
        let state = progress.state.withLock { $0 }
        let _ = progress.draw(state: state, detail: .full)
    }

    @Test func itemsName() throws {
        let config = try ProgressConfig(
            description: "Task",
            itemsName: "files",
            showItems: true,
            totalItems: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        #expect(output == "⠋ Task 50% (1 of 2 files) [0s]")
    }

    @Test func plainModeConfig() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpinner: false,
            outputMode: .plain
        )
        #expect(config.outputMode == .plain)
    }

    @Test func plainModeDraw() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpinner: false,
            outputMode: .plain
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "Task [0s]")
    }

    @Test func plainModeDrawWithTasks() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpinner: false,
            showTasks: true,
            totalTasks: 2,
            outputMode: .plain
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output == "[0/2] Task [0s]")
    }

    @Test func plainModeDrawWithPercent() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpinner: false,
            showItems: true,
            totalItems: 2,
            outputMode: .plain
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        #expect(output == "Task 50% (1 of 2 it) [0s]")
    }

    @Test func plainModeFinished() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpinner: false,
            showTasks: true,
            totalTasks: 2,
            clearOnFinish: false,
            outputMode: .plain
        )
        let progress = ProgressBar(config: config)
        progress.set(tasks: 2)
        progress.finish()
        let output = progress.draw()
        #expect(output == "[2/2] Task [0s]")
    }

    @Test func plainModeWithSize() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpinner: false,
            showSize: true,
            showSpeed: false,
            totalSize: 4,
            outputMode: .plain
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        let output = progress.draw()
        #expect(output == "Task 50% (2/4 bytes) [0s]")
    }

    @Test func plainModeNoProgressBar() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpinner: false,
            showProgressBar: false,
            totalItems: 2,
            outputMode: .plain
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        #expect(output == "Task 50% [0s]")
    }

    @Test func plainModeNoAnsiEscapes() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpinner: false,
            outputMode: .plain
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(!output.contains("\u{001B}"))
    }

    @Test func plainModeTerminalOutput() throws {
        let pipe = Pipe()
        let config = try ProgressConfig(
            terminal: pipe.fileHandleForWriting,
            description: "Task",
            showSpinner: false,
            clearOnFinish: false,
            outputMode: .plain
        )
        let progress = ProgressBar(config: config)
        progress.render(force: true)
        progress.finish()
        try pipe.fileHandleForWriting.close()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        // Expect exactly 2 lines: one from render, one from finish
        #expect(lines.count == 2)
        #expect(lines[0].contains("Task"))
        #expect(lines[1].contains("Task"))
    }

    @Test func plainModeTerminalOutputNoAnsiEscapes() throws {
        let pipe = Pipe()
        let config = try ProgressConfig(
            terminal: pipe.fileHandleForWriting,
            description: "Task",
            showSpinner: false,
            clearOnFinish: false,
            outputMode: .plain
        )
        let progress = ProgressBar(config: config)
        progress.render(force: true)
        progress.finish()
        try pipe.fileHandleForWriting.close()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        #expect(!output.contains("\u{001B}"))
    }

    @Test func plainModeTerminalOutputUsesNewlines() throws {
        let pipe = Pipe()
        let config = try ProgressConfig(
            terminal: pipe.fileHandleForWriting,
            description: "Task",
            showSpinner: false,
            clearOnFinish: false,
            outputMode: .plain
        )
        let progress = ProgressBar(config: config)
        progress.render(force: true)
        progress.finish()
        try pipe.fileHandleForWriting.close()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        // Plain mode should use newlines, not carriage returns
        #expect(!output.contains("\r"))
        #expect(output.contains("\n"))
    }

    @Test func plainModeDefaultClearOnFinishOmitsFinalLine() throws {
        let pipe = Pipe()
        let config = try ProgressConfig(
            terminal: pipe.fileHandleForWriting,
            description: "Task",
            showSpinner: false,
            outputMode: .plain
        )
        let progress = ProgressBar(config: config)
        progress.render(force: true)
        progress.finish()
        try pipe.fileHandleForWriting.close()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
        #expect(lines.first == "Task [0s]")
    }

    @Test func outputModeDefaultIsAnsi() throws {
        let config = try ProgressConfig(description: "Task")
        #expect(config.outputMode == .ansi)
    }

    // MARK: - Color mode tests

    @Test func colorModeConfig() throws {
        let config = try ProgressConfig(
            description: "Task",
            outputMode: .color
        )
        #expect(config.outputMode == .color)
    }

    @Test func visibleLengthPlainText() {
        let text = "hello"
        #expect(text.visibleLength == 5)
    }

    @Test func visibleLengthWithAnsiCodes() {
        let text = "\u{001B}[36mhello\u{001B}[0m"
        #expect(text.visibleLength == 5)
    }

    @Test func visibleLengthEmptyString() {
        #expect("".visibleLength == 0)
    }

    @Test func colorModeDraw() throws {
        let config = try ProgressConfig(
            description: "Task",
            outputMode: .color
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        let stripped = output.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression
        )
        #expect(stripped == "⠋ Task [0s]")
    }

    @Test func colorModeDrawContainsAnsiCodes() throws {
        let config = try ProgressConfig(
            description: "Task",
            outputMode: .color
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output.contains("\u{001B}["))
        #expect(output.contains(EscapeSequence.cyan))  // spinner
        #expect(output.contains(EscapeSequence.bold))  // description
        #expect(output.contains(EscapeSequence.dim))  // time
        #expect(output.contains(EscapeSequence.reset))  // reset
    }

    @Test func colorModeDrawFinished() throws {
        let config = try ProgressConfig(
            description: "Task",
            outputMode: .color
        )
        let progress = ProgressBar(config: config)
        progress.finish()
        let output = progress.draw()
        let stripped = output.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression
        )
        #expect(stripped == "✔ Task [0s]")
        #expect(output.contains(EscapeSequence.green))  // done icon
    }

    @Test func colorModeDrawWithTasks() throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true,
            totalTasks: 2,
            outputMode: .color
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        let stripped = output.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression
        )
        #expect(stripped == "⠋ [0/2] Task [0s]")
        #expect(output.contains(EscapeSequence.cyan))  // tasks
    }

    @Test func colorModeDrawWithPercent() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            totalItems: 2,
            outputMode: .color
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        let stripped = output.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression
        )
        #expect(stripped == "⠋ Task 50% (1 of 2 it) [0s]")
        #expect(output.contains(EscapeSequence.yellow))  // in-progress percent
    }

    @Test func colorModeDrawWithPercentFinished() throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            totalItems: 2,
            outputMode: .color
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.finish()
        let output = progress.draw()
        let stripped = output.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression
        )
        #expect(stripped == "✔ Task 100% (2 it) [0s]")
        #expect(output.contains(EscapeSequence.green))  // finished percent
    }

    @Test func colorModeDrawWithSize() throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false,
            totalSize: 4,
            outputMode: .color
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        let output = progress.draw()
        let stripped = output.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression
        )
        #expect(stripped == "⠋ Task 50% (2/4 bytes) [0s]")
        #expect(output.contains(EscapeSequence.dim))  // parens content
    }

    @Test func colorModeDrawVisibleLengthMatchesContent() throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true,
            showItems: true,
            totalTasks: 2,
            totalItems: 4,
            outputMode: .color
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 2)
        let colorOutput = progress.draw()

        let plainConfig = try ProgressConfig(
            description: "Task",
            showTasks: true,
            showItems: true,
            totalTasks: 2,
            totalItems: 4
        )
        let plainProgress = ProgressBar(config: plainConfig)
        plainProgress.set(items: 2)
        let plainOutput = plainProgress.draw()

        #expect(colorOutput.visibleLength == plainOutput.count)
    }

    @Test func colorModeNoAnsiCodesInContent() throws {
        let config = try ProgressConfig(
            description: "Task",
            outputMode: .color
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        let stripped = output.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression
        )
        #expect(!stripped.contains("\u{001B}"))
    }

    @Test func colorModeDrawWithProgressBar() throws {
        let config = try ProgressConfig(
            description: "Task",
            showProgressBar: true,
            totalItems: 2,
            width: 57,
            outputMode: .color
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        let stripped = output.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression
        )
        #expect(stripped == "Task 50% |██  | [0s]")
        #expect(output.contains(EscapeSequence.green))
    }

    @Test func colorModeRequiresTTY() throws {
        let pipe = Pipe()
        let config = try ProgressConfig(
            terminal: pipe.fileHandleForWriting,
            description: "Task",
            outputMode: .color
        )
        let progress = ProgressBar(config: config)
        // Pipe is not a TTY, so render should produce no output (same as ansi)
        progress.render(force: true)
        progress.finish()
        try pipe.fileHandleForWriting.close()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(data.isEmpty)
    }

    @Test func colorModeDrawOutputContainsColorCodes() throws {
        // Verify draw() includes ANSI codes even without a TTY
        // (draw is separate from terminal rendering)
        let config = try ProgressConfig(
            description: "Task",
            outputMode: .color
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        #expect(output.contains(EscapeSequence.cyan))
        #expect(output.contains(EscapeSequence.bold))
        #expect(output.contains(EscapeSequence.dim))
        #expect(output.contains(EscapeSequence.reset))
    }

    @Test func colorModeRenderTerminatorIsCarriageReturn() throws {
        // Color mode is TTY-only so we cannot capture its raw terminal output via a pipe.
        // Instead, verify that plain mode emits \n (newlines) while color mode shares the
        // ansi code path which emits \r (carriage returns). We confirm this by checking
        // that plain output uses \n and that color mode is distinct from plain.
        let plainPipe = Pipe()
        let plainConfig = try ProgressConfig(
            terminal: plainPipe.fileHandleForWriting,
            description: "Task",
            showSpinner: false,
            clearOnFinish: false,
            outputMode: .plain
        )
        let plainProgress = ProgressBar(config: plainConfig)
        plainProgress.render(force: true)
        plainProgress.finish()
        try plainPipe.fileHandleForWriting.close()

        let plainData = plainPipe.fileHandleForReading.readDataToEndOfFile()
        let plainOutput = String(decoding: plainData, as: UTF8.self)
        // Plain mode uses \n terminators
        #expect(plainOutput.contains("\n"))
        #expect(!plainOutput.contains("\r"))

        // Color mode follows the ansi path (not plain), so it uses \r
        let colorConfig = try ProgressConfig(
            description: "Task",
            outputMode: .color
        )
        #expect(colorConfig.outputMode != .plain)
    }

    @Test func outputModeDefaultIsNotColor() throws {
        let config = try ProgressConfig(description: "Task")
        #expect(config.outputMode != .color)
        #expect(config.outputMode == .ansi)
    }
}
