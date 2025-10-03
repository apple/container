//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
    /// A configuration struct for the progress bar.
    public struct State {
        /// A flag indicating whether the progress bar is finished.
        public var finished = false
        var iteration = 0
        private let speedInterval: DispatchTimeInterval = .seconds(1)

        var description: String
        var subDescription: String
        var itemsName: String

        var tasks: Int
        var totalTasks: Int?

        var items: Int
        var totalItems: Int?

        private var sizeUpdateTime: DispatchTime?
        private var sizeUpdateValue: Int64 = 0
        var size: Int64 {
            didSet {
                calculateSizeSpeed()
            }
        }
        var totalSize: Int64?
        private var sizeUpdateSpeed: String?
        var sizeSpeed: String? {
            guard sizeUpdateTime == nil || sizeUpdateTime! > .now() - speedInterval - speedInterval else {
                return Int64(0).formattedSizeSpeed(from: startTime)
            }
            return sizeUpdateSpeed
        }
        var averageSizeSpeed: String {
            size.formattedSizeSpeed(from: startTime)
        }

        var percent: String {
            var value = 0
            if let totalSize, totalSize > 0 {
                value = Int(size * 100 / totalSize)
            } else if let totalItems, totalItems > 0 {
                value = Int(items * 100 / totalItems)
            }
            value = min(value, 100)
            return "\(value)%"
        }

        var startTime: DispatchTime
        var output = ""

        init(
            description: String = "", subDescription: String = "", itemsName: String = "", tasks: Int = 0, totalTasks: Int? = nil, items: Int = 0, totalItems: Int? = nil,
            size: Int64 = 0, totalSize: Int64? = nil, startTime: DispatchTime = .now()
        ) {
            self.description = description
            self.subDescription = subDescription
            self.itemsName = itemsName
            self.tasks = tasks
            self.totalTasks = totalTasks
            self.items = items
            self.totalItems = totalItems
            self.size = size
            self.totalSize = totalSize
            self.startTime = startTime
        }

        private mutating func calculateSizeSpeed() {
            if sizeUpdateTime == nil || sizeUpdateTime! < .now() - speedInterval {
                let partSize = size - sizeUpdateValue
                let partStartTime = sizeUpdateTime ?? startTime
                let partSizeSpeed = partSize.formattedSizeSpeed(from: partStartTime)
                self.sizeUpdateSpeed = partSizeSpeed

                sizeUpdateTime = .now()
                sizeUpdateValue = size
            }
        }
    }
}
