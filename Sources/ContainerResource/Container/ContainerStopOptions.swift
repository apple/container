//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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

public struct ContainerStopOptions: Sendable, Codable {
    public let timeoutInSeconds: Int32
    public let signal: Int32

    public static let `default` = ContainerStopOptions(
        timeoutInSeconds: 5,
        signal: SIGTERM
    )

    public init(timeoutInSeconds: Int32, signal: Int32) {
        self.timeoutInSeconds = timeoutInSeconds
        self.signal = signal
    }
}
