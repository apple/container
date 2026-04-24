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
import SystemPackage

public enum UserConfiguration {
    public enum BaseConfigPath {
        case home
        case appRoot
    }

    public static func basePath(for base: BaseConfigPath) -> FilePath {
        switch base {
        case .home:
            let configHome: String
            if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
                configHome = xdg
            } else {
                configHome = NSHomeDirectory()
            }
            return FilePath(configHome).appending(".container")
        case .appRoot:
            if let envPath = ProcessInfo.processInfo.environment["CONTAINER_APP_ROOT"], !envPath.isEmpty {
                return FilePath(envPath)
            }
            let appSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("com.apple.container")
            return FilePath(appSupportURL.path(percentEncoded: false))
        }
    }

    public static func resolve(basePath: FilePath, relativePath: String) -> FilePath? {
        let full = basePath.appending(relativePath)
        guard FileManager.default.fileExists(atPath: full.string) else { return nil }
        return full
    }

    public static func resolve(from base: BaseConfigPath, relativePath: String) -> FilePath? {
        resolve(basePath: basePath(for: base), relativePath: relativePath)
    }
}
