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
import Logging

/// Describes the configuration and binary file locations for a plugin.
public protocol PluginFactory: Sendable {
    /// Create a plugin from the plugin path, if it conforms to the layout.
    func create(installURL: URL) throws -> Plugin?
    /// Create a plugin from the plugin parent path and name, if it conforms to the layout.
    func create(parentURL: URL, name: String) throws -> Plugin?
}

/// Default layout which uses a Unix-like structure.
public struct DefaultPluginFactory: PluginFactory {
    // Order matters: earlier entries take priority during config file discovery.
    private static let configFilenames: [String] = ["config.toml", "config.json"]
    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    /// Returns the URL of the first config file found in `directory`, preferring TOML over JSON.
    static func findConfigURL(in directory: URL, logger: Logger) -> URL? {
        let fm = FileManager.default
        for filename in configFilenames {
            let url = directory.appending(path: filename)
            if fm.fileExists(atPath: url.path) {
                if url.pathExtension == "json" {
                    logger.warning(
                        "Plugin using legacy config.json; please migrate to config.toml",
                        metadata: ["path": "\(url.path)"]
                    )
                }
                return url
            }
        }
        return nil
    }

    public func create(installURL: URL) throws -> Plugin? {
        let fm = FileManager.default

        guard let configURL = Self.findConfigURL(in: installURL, logger: logger) else {
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

        var resourceURL: URL? = nil
        if case let url = installURL.appending(path: "resources"), fm.fileExists(atPath: url.path) {
            resourceURL = url
        }
        return Plugin(binaryURL: binaryURL, config: config, resourceURL: resourceURL)
    }

    public func create(parentURL: URL, name: String) throws -> Plugin? {
        try create(installURL: parentURL.appendingPathComponent(name))
    }
}

/// Layout which uses a macOS application bundle structure.
public struct AppBundlePluginFactory: PluginFactory {
    private static let appSuffix = ".app"
    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    public func create(installURL: URL) throws -> Plugin? {
        let fm = FileManager.default

        let contentResources =
            installURL
            .appending(path: "Contents")
            .appending(path: "Resources")

        guard let configURL = DefaultPluginFactory.findConfigURL(in: contentResources, logger: logger) else {
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

        var resourceURL: URL? = nil
        if case let url = contentResources.appending(path: "resources"), fm.fileExists(atPath: url.path) {
            resourceURL = url
        }

        return Plugin(binaryURL: binaryURL, config: config, resourceURL: resourceURL)
    }

    public func create(parentURL: URL, name: String) throws -> Plugin? {
        try create(installURL: parentURL.appendingPathComponent("\(name)\(Self.appSuffix)"))
    }
}
