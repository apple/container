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

extension CommandLine {
    public static var executablePathUrl: URL {
        /// _NSGetExecutablePath with a zero-length buffer returns the needed buffer length
        var bufferSize: Int32 = 0
        var buffer = [CChar](repeating: 0, count: Int(bufferSize))
        _ = _NSGetExecutablePath(&buffer, &bufferSize)

        /// Create the buffer and get the path
        buffer = [CChar](repeating: 0, count: Int(bufferSize))
        guard _NSGetExecutablePath(&buffer, &bufferSize) == 0 else {
            fatalError("unexpected: failed to get executable path")
        }

        /// Return the path with the executable file component removed the last component and
        let executablePath = String(cString: &buffer)
        return URL(filePath: executablePath)
    }
}
