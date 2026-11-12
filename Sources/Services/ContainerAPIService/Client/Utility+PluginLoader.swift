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

import ContainerPlugin
import ContainerizationError
import Foundation
import Logging
import SystemPackage

extension Utility {
    public static func createPluginLoader(log: Logger) async throws -> PluginLoader {
        let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        // TODO: Remove when we convert PluginLoader to FilePath.
        let installRootPath = FilePath(health.installRoot.path(percentEncoded: false))
        let userPluginsURL = PluginLoader.userPluginsDir(installRoot: health.installRoot)
        var directoryExists: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: userPluginsURL.path, isDirectory: &directoryExists)

        // plugins built into the application installed as a macOS app bundle
        let appBundlePluginsURL = Bundle.main.resourceURL?.appending(path: "plugins")

        // plugins built into the application installed as a Unix-like application
        let installRootPluginsPath =
            installRootPath
            .appending(FilePath.Component("libexec"))
            .appending(FilePath.Component("container"))
            .appending(FilePath.Component("plugins"))
        let installRootPluginsURL = URL(fileURLWithPath: installRootPluginsPath.string)
        let pluginDirectories = [
            directoryExists.boolValue ? userPluginsURL : nil,
            appBundlePluginsURL,
            installRootPluginsURL,
        ].compactMap { $0 }

        let pluginFactories: [any PluginFactory] = [
            DefaultPluginFactory(logger: log),
            AppBundlePluginFactory(logger: log),
        ]

        guard let systemHealth = try? await ClientHealthCheck.ping(timeout: .seconds(10)) else {
            throw ContainerizationError(.timeout, message: "unable to retrieve application data root from API server")
        }
        return try PluginLoader(
            appRoot: systemHealth.appRoot,
            installRoot: systemHealth.installRoot,
            logRoot: systemHealth.logRoot,
            pluginDirectories: pluginDirectories,
            pluginFactories: pluginFactories,
            log: log
        )
    }
}
