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

private let configFilename: String = "config.json"

/// Describes the configuration and binary file locations for a plugin.
public protocol PluginFactory: Sendable {
    /// Create a plugin from the plugin path, if it conforms to the layout.
    func create(installURL: URL) throws -> Plugin?
    /// Create a plugin from the plugin parent path and name, if it conforms to the layout.
    func create(parentURL: URL, name: String) throws -> Plugin?
}

/// Default layout which uses a Unix-like structure.
public struct DefaultPluginFactory: PluginFactory {
    public init() {}

    public func create(installURL: URL) throws -> Plugin? {
        let fm = FileManager.default

        let configURL = installURL.appending(path: configFilename)
        guard fm.fileExists(atPath: configURL.path) else {
            return nil
        }

        guard let config = try PluginConfig(configURL: configURL) else {
            return nil
        }

        let name = installURL.lastPathComponent
        let binaryURL = installURL.appending(path: "bin").appending(path: name)
        guard fm.fileExists(atPath: binaryURL.path) else {
            return nil
        }

        return Plugin(binaryURL: binaryURL, config: config)
    }

    public func create(parentURL: URL, name: String) throws -> Plugin? {
        try create(installURL: parentURL.appendingPathComponent(name))
    }
}

/// Layout which uses a macOS application bundle structure.
public struct AppBundlePluginFactory: PluginFactory {
    private static let appSuffix = ".app"

    public init() {}

    public func create(installURL: URL) throws -> Plugin? {
        let fm = FileManager.default

        let configURL =
            installURL
            .appending(path: "Contents")
            .appending(path: "Resources")
            .appending(path: configFilename)
        guard fm.fileExists(atPath: configURL.path) else {
            return nil
        }

        guard let config = try PluginConfig(configURL: configURL) else {
            return nil
        }

        let appName = installURL.lastPathComponent
        guard appName.hasSuffix(Self.appSuffix) else {
            return nil
        }
        let name = String(appName.dropLast(Self.appSuffix.count))
        let binaryURL =
            installURL
            .appending(path: "Contents")
            .appending(path: "MacOS")
            .appending(path: name)
        guard fm.fileExists(atPath: binaryURL.path) else {
            return nil
        }

        return Plugin(binaryURL: binaryURL, config: config)
    }

    public func create(parentURL: URL, name: String) throws -> Plugin? {
        try create(installURL: parentURL.appendingPathComponent("\(name)\(Self.appSuffix)"))
    }
}
