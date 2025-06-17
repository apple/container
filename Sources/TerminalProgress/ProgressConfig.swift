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

/// A configuration for displaying a progress bar.
public struct ProgressConfig: Sendable {
    /// The file handle for progress updates.
    let terminal: FileHandle
    /// The initial description of the progress bar.
    let initialDescription: String
    /// The initial additional description of the progress bar.
    let initialSubDescription: String
    /// The initial items name (e.g., "files").
    let initialItemsName: String
    /// A flag indicating whether to show a spinner (e.g., "⠋").
    /// The spinner is hidden when a progress bar is shown.
    public let showSpinner: Bool
    /// A flag indicating whether to show tasks and total tasks (e.g., "[1]" or "[1/3]").
    public let showTasks: Bool
    /// A flag indicating whether to show the description (e.g., "Downloading...").
    public let showDescription: Bool
    /// A flag indicating whether to show a percentage (e.g., "100%").
    /// The percentage is hidden when no total size and total items are set.
    public let showPercent: Bool
    /// A flag indicating whether to show a progress bar (e.g., "|███            |").
    /// The progress bar is hidden when no total size and total items are set.
    public let showProgressBar: Bool
    /// A flag indicating whether to show items and total items (e.g., "(22 it)" or "(22/22 it)").
    public let showItems: Bool
    /// A flag indicating whether to show a size and a total size (e.g., "(22 MB)" or "(22/22 MB)").
    public let showSize: Bool
    /// A flag indicating whether to show a speed (e.g., "(4.834 MB/s)").
    /// The speed is combined with the size and total size (e.g., "(22/22 MB, 4.834 MB/s)").
    /// The speed is hidden when no total size is set.
    public let showSpeed: Bool
    /// A flag indicating whether to show the elapsed time (e.g., "[4s]").
    public let showTime: Bool
    /// The flag indicating whether to ignore small size values (less than 1 MB). For example, this may help to avoid reaching 100% after downloading metadata before downloading content.
    public let ignoreSmallSize: Bool
    /// The initial total tasks of the progress bar.
    let initialTotalTasks: Int?
    /// The initial total size of the progress bar.
    let initialTotalSize: Int64?
    /// The initial total items of the progress bar.
    let initialTotalItems: Int?
    /// The width of the progress bar in characters.
    public let width: Int
    /// The theme of the progress bar.
    public let theme: ProgressTheme
    /// The flag indicating whether to clear the progress bar before resetting the cursor.
    public let clearOnFinish: Bool
    /// The flag indicating whether to update the progress bar.
    public let disableProgressUpdates: Bool
    /// Creates a new instance of `ProgressConfig`.
    /// - Parameters:
    ///   - terminal: The file handle for progress updates. The default value is `FileHandle.standardError`.
    ///   - description: The initial description of the progress bar. The default value is `""`.
    ///   - subDescription: The initial additional description of the progress bar. The default value is `""`.
    ///   - itemsName: The initial items name. The default value is `"it"`.
    ///   - showSpinner: A flag indicating whether to show a spinner. The default value is `true`.
    ///   - showTasks: A flag indicating whether to show tasks and total tasks. The default value is `false`.
    ///   - showDescription: A flag indicating whether to show the description. The default value is `true`.
    ///   - showPercent: A flag indicating whether to show a percentage. The default value is `true`.
    ///   - showProgressBar: A flag indicating whether to show a progress bar. The default value is `false`.
    ///   - showItems: A flag indicating whether to show items and a total items. The default value is `false`.
    ///   - showSize: A flag indicating whether to show a size and a total size. The default value is `true`.
    ///   - showSpeed: A flag indicating whether to show a speed. The default value is `true`.
    ///   - showTime: A flag indicating whether to show the elapsed time. The default value is `true`.
    ///   - ignoreSmallSize: A flag indicating whether to ignore small size values. The default value is `false`.
    ///   - totalTasks: The initial total tasks of the progress bar. The default value is `nil`.
    ///   - totalItems: The initial total items of the progress bar. The default value is `nil`.
    ///   - totalSize: The initial total size of the progress bar. The default value is `nil`.
    ///   - width: The width of the progress bar in characters. The default value is `120`.
    ///   - theme: The theme of the progress bar. The default value is `nil`.
    ///   - clearOnFinish: The flag indicating whether to clear the progress bar before resetting the cursor. The default is `true`.
    ///   - disableProgressUpdates: The flag indicating whether to update the progress bar. The default is `false`.
    public init(
        terminal: FileHandle = .standardError,
        description: String = "",
        subDescription: String = "",
        itemsName: String = "it",
        showSpinner: Bool = true,
        showTasks: Bool = false,
        showDescription: Bool = true,
        showPercent: Bool = true,
        showProgressBar: Bool = false,
        showItems: Bool = false,
        showSize: Bool = true,
        showSpeed: Bool = true,
        showTime: Bool = true,
        ignoreSmallSize: Bool = false,
        totalTasks: Int? = nil,
        totalItems: Int? = nil,
        totalSize: Int64? = nil,
        width: Int = 120,
        theme: ProgressTheme? = nil,
        clearOnFinish: Bool = true,
        disableProgressUpdates: Bool = false
    ) throws {
        if let totalTasks {
            guard totalTasks > 0 else {
                throw Error.invalid("totalTasks must be greater than zero")
            }
        }
        if let totalItems {
            guard totalItems > 0 else {
                throw Error.invalid("totalItems must be greater than zero")
            }
        }
        if let totalSize {
            guard totalSize > 0 else {
                throw Error.invalid("totalSize must be greater than zero")
            }
        }

        self.terminal = terminal
        self.initialDescription = description
        self.initialSubDescription = subDescription
        self.initialItemsName = itemsName

        self.showSpinner = showSpinner
        self.showTasks = showTasks
        self.showDescription = showDescription
        self.showPercent = showPercent
        self.showProgressBar = showProgressBar
        self.showItems = showItems
        self.showSize = showSize
        self.showSpeed = showSpeed
        self.showTime = showTime

        self.ignoreSmallSize = ignoreSmallSize
        self.initialTotalTasks = totalTasks
        self.initialTotalItems = totalItems
        self.initialTotalSize = totalSize

        self.width = width
        self.theme = theme ?? DefaultProgressTheme()
        self.clearOnFinish = clearOnFinish
        self.disableProgressUpdates = disableProgressUpdates
    }
}

extension ProgressConfig {
    /// An enumeration of errors that can occur when creating a `ProgressConfig`.
    public enum Error: Swift.Error, CustomStringConvertible {
        case invalid(String)

        /// The description of the error.
        public var description: String {
            switch self {
            case .invalid(let reason):
                return "Failed to validate config (\(reason))"
            }
        }
    }
}
