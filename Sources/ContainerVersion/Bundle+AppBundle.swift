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

/// Retrieve the application bundle for a path that refers to a macOS executable.
extension Bundle {
    public static func appBundle(executableURL: URL) -> Bundle? {
        let resolvedURL = executableURL.resolvingSymlinksInPath()
        let macOSURL = resolvedURL.deletingLastPathComponent()
        let contentsURL = macOSURL.deletingLastPathComponent()
        let bundleURL = contentsURL.deletingLastPathComponent()
        if bundleURL.pathExtension == "app" {
            return Bundle(url: bundleURL)
        }
        return nil
    }
}
