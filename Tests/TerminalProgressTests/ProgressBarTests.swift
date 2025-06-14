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

//

import XCTest

@testable import TerminalProgress

final class ProgressBarTests: XCTestCase {
    func testSpinner() async throws {
        let config = try ProgressConfig(
            description: "Task"
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testSpinnerFinished() async throws {
        let config = try ProgressConfig(
            description: "Task"
        )
        let progress = ProgressBar(config: config)
        progress.finish()
        let output = progress.draw()
        XCTAssertEqual(output, "✔ Task [0s]")
    }

    func testNoSpinner() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpinner: false
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "Task [0s]")
    }

    func testNoSpinnerFinished() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpinner: false
        )
        let progress = ProgressBar(config: config)
        progress.finish()
        let output = progress.draw()
        XCTAssertEqual(output, "Task [0s]")
    }

    func testNoTasks() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: false
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testTasks() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testTasksAdd() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true
        )
        let progress = ProgressBar(config: config)
        progress.add(tasks: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testTasksSet() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true
        )
        let progress = ProgressBar(config: config)
        progress.set(tasks: 2)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testTotalTasks() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true,
            totalTasks: 2
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ [0/2] Task [0s]")
    }

    func testTotalTasksFinished() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true,
            totalTasks: 2
        )
        let progress = ProgressBar(config: config)
        progress.finish()
        let output = progress.draw()
        XCTAssertEqual(output, "✔ [0/2] Task [0s]")
    }

    func testTotalTasksAdd() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true,
            totalTasks: 1
        )
        let progress = ProgressBar(config: config)
        progress.add(totalTasks: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ [0/2] Task [0s]")
    }

    func testTotalTasksSet() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showTasks: true,
            totalTasks: 1
        )
        let progress = ProgressBar(config: config)
        progress.set(totalTasks: 2)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ [0/2] Task [0s]")
    }

    func testTotalTasksInvalid() throws {
        do {
            let _ = try ProgressConfig(description: "test", totalTasks: 0)
        } catch ProgressConfig.Error.invalid(_) {
            return
        }
        XCTFail("expected ProgressConfig.Error.invalid")
    }

    func testDescription() async throws {
        let config = try ProgressConfig(
            description: "Task"
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testNoDescription() async throws {
        let config = try ProgressConfig()
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ [0s]")
    }

    func testNoPercent() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showPercent: false,
            totalItems: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testPercentHidden() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showPercent: true
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testPercentItems() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showPercent: true,
            totalItems: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task 50% [0s]")
    }

    func testPercentItemsFinished() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showPercent: true,
            totalItems: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.finish()
        let output = progress.draw()
        XCTAssertEqual(output, "✔ Task 100% [0s]")
    }

    func testPercentSize() async throws {
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
        XCTAssertEqual(output, "⠋ Task 50% [0s]")
    }

    func testPercentSizeFinished() async throws {
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
        XCTAssertEqual(output, "✔ Task 100% [0s]")
    }

    func testNoProgressBar() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showProgressBar: false,
            totalItems: 2,
            width: 57
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task 50% [0s]")
    }

    func testProgressBar() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showProgressBar: true,
            totalItems: 2,
            width: 57
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "Task 50% |██  | [0s]")
    }

    func testProgressBarFinished() async throws {
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
        XCTAssertEqual(output, "Task 100% |███| [0s]")
    }

    func testProgressBarMinWidth() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showProgressBar: true,
            totalItems: 2,
            width: 13
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "Task 50% | | [0s]")
    }

    func testProgressBarMinWidthFinished() async throws {
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
        XCTAssertEqual(output, "Task 100% |█| [0s]")
    }

    func testNoItems() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: false
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testItemsZero() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testItemsAdd() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true
        )
        let progress = ProgressBar(config: config)
        progress.add(items: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task (1 it) [0s]")
    }

    func testItemsAddFinish() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true
        )
        let progress = ProgressBar(config: config)
        progress.add(items: 1)
        progress.finish()
        let output = progress.draw()
        XCTAssertEqual(output, "✔ Task [0s]")
    }

    func testItemsSet() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 2)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task (2 it) [0s]")
    }

    func testTotalItemsZeroItems() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            totalItems: 1
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task 0% [0s]")
    }

    func testTotalItems() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            totalItems: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task 50% (1 of 2 it) [0s]")
    }

    func testTotalItemsFinish() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            totalItems: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.finish()
        let output = progress.draw()
        XCTAssertEqual(output, "✔ Task 100% (2 it) [0s]")
    }

    func testTotalItemsAdd() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            totalItems: 1
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.add(totalItems: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task 50% (1 of 2 it) [0s]")
    }

    func testTotalItemsSet() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showItems: true,
            totalItems: 1
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        progress.set(totalItems: 2)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task 50% (1 of 2 it) [0s]")
    }

    func testTotalItemsInvalid() throws {
        do {
            let _ = try ProgressConfig(description: "test", totalItems: 0)
        } catch ProgressConfig.Error.invalid(_) {
            return
        }
        XCTFail("expected ProgressConfig.Error.invalid")
    }

    func testNoSize() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: false
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testSizeZero() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testSizeAdd() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false
        )
        let progress = ProgressBar(config: config)
        progress.add(size: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task (1 byte) [0s]")
    }

    func testSizeAddFinish() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false
        )
        let progress = ProgressBar(config: config)
        progress.add(size: 1)
        progress.finish()
        let output = progress.draw()
        XCTAssertEqual(output, "✔ Task [0s]")
    }

    func testSizeSet() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task (2 bytes) [0s]")
    }

    func testTotalSizeZeroSize() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            totalSize: 1
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task 0% [0s]")
    }

    func testTotalSizeDifferentUnits() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false,
            totalSize: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task 50% (1 byte/2 bytes) [0s]")
    }

    func testTotalSizeDifferentUnitsFinish() async throws {
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
        XCTAssertEqual(output, "✔ Task 100% (2 bytes) [0s]")
    }

    func testTotalSizeSameUnits() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSize: true,
            showSpeed: false,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task 50% (2/4 bytes) [0s]")
    }

    func testTotalSizeSameUnitsFinish() async throws {
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
        XCTAssertEqual(output, "✔ Task 100% (4 bytes) [0s]")
    }

    func testTotalSizeAdd() async throws {
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
        XCTAssertEqual(output, "⠋ Task 50% (2/4 bytes) [0s]")
    }

    func testTotalSizeSet() async throws {
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
        XCTAssertEqual(output, "⠋ Task 50% (2/4 bytes) [0s]")
    }

    func testTotalSizeInvalid() throws {
        do {
            let _ = try ProgressConfig(description: "test", totalSize: 0)
        } catch ProgressConfig.Error.invalid(_) {
            return
        }
        XCTFail("expected ProgressConfig.Error.invalid")
    }

    func testItemsAndSize() async throws {
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
        XCTAssertEqual(output, "⠋ Task 50% (1 of 2 it, 2/4 bytes) [0s]")
    }

    func testItemsAndSizeFinish() async throws {
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
        XCTAssertEqual(output, "✔ Task 100% (2 it, 4 bytes) [0s]")
    }

    func testNoSpeed() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpeed: false,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task 50% (2/4 bytes) [0s]")
    }

    func testSpeed() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpeed: true,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        let output = progress.draw()
        XCTAssertTrue(output.contains("/s"))
    }

    func testSpeedFinish() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showSpeed: true,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        progress.finish()
        let output = progress.draw()
        XCTAssertFalse(output.contains("/s"))
    }

    func testItemsSizeAndSpeed() async throws {
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
        XCTAssertTrue(output.contains("1 of 2 it, 2/4 bytes"))
        XCTAssertTrue(output.contains("/s"))
    }

    func testItemsSizeAndSpeedFinish() async throws {
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
        XCTAssertTrue(output.contains("2 it, 4 bytes"))
        XCTAssertFalse(output.contains("/s"))
    }

    func testNoTime() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showTime: false
        )
        let progress = ProgressBar(config: config)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task")
    }

    func testTime() async throws {
        let config = try ProgressConfig(
            description: "Task",
            showTime: true
        )
        let progress = ProgressBar(config: config)
        sleep(1)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [1s]")
    }

    func testIgnoreSmallSize() async throws {
        let config = try ProgressConfig(
            description: "Task",
            ignoreSmallSize: true,
            totalSize: 4
        )
        let progress = ProgressBar(config: config)
        progress.set(size: 2)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task [0s]")
    }

    func testItemsName() async throws {
        let config = try ProgressConfig(
            description: "Task",
            itemsName: "files",
            showItems: true,
            totalItems: 2
        )
        let progress = ProgressBar(config: config)
        progress.set(items: 1)
        let output = progress.draw()
        XCTAssertEqual(output, "⠋ Task 50% (1 of 2 files) [0s]")
    }
}
