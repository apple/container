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

extension Int {
    func formattedTime() -> String {
        let secondsInMinute = 60
        let secondsInHour = secondsInMinute * 60
        let secondsInDay = secondsInHour * 24

        let days = self / secondsInDay
        let hours = (self % secondsInDay) / secondsInHour
        let minutes = (self % secondsInHour) / secondsInMinute
        let seconds = self % secondsInMinute

        var components = [String]()
        if days > 0 {
            components.append("\(days)d")
        }
        if hours > 0 || days > 0 {
            components.append("\(hours)h")
        }
        if minutes > 0 || hours > 0 || days > 0 {
            components.append("\(minutes)m")
        }
        components.append("\(seconds)s")
        return components.joined(separator: " ")
    }

    func formattedNumber() -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        guard let formattedNumber = formatter.string(from: NSNumber(value: self)) else {
            return ""
        }
        return formattedNumber
    }
}
