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

extension Int64 {
    func formattedSize() -> String {
        let formattedSize = ByteCountFormatter.string(fromByteCount: self, countStyle: .binary)
        return formattedSize
    }

    func formattedSizeSpeed(from startTime: DispatchTime) -> String {
        let elapsedTimeNanoseconds = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let elapsedTimeSeconds = Double(elapsedTimeNanoseconds) / 1_000_000_000
        guard elapsedTimeSeconds > 0 else {
            return "0 B/s"
        }

        let speed = Double(self) / elapsedTimeSeconds
        let formattedSpeed = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .binary)
        return "\(formattedSpeed)/s"
    }
}
