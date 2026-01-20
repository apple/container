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

/// Provides the application data root path.
public struct ApplicationRoot {
    public static let environmentName = "CONTAINER_APP_ROOT"

    public static let defaultURL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first!.appendingPathComponent("com.apple.container")

    private static let envPath = ProcessInfo.processInfo.environment[Self.environmentName]

    public static let url = envPath.map { URL(fileURLWithPath: $0) } ?? defaultURL

    public static let path = url.path(percentEncoded: false)
}
