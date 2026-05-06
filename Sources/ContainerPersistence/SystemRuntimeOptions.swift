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

import ContainerizationError
import Foundation
import Logging
import SystemPackage
import TOML

private let log = Logger(label: "SystemRuntimeOptions")

/// TOML-backed configuration loader.
///
/// Decodes a user-provided TOML file into a typed configuration struct.
/// Missing keys fall back to the struct's hardcoded defaults (via custom
/// `init(from:)` implementations using `decodeIfPresent`).
///
/// Configuration priority (highest to lowest):
/// 1. User config: `$XDG_CONFIG_HOME/container/runtime-config.toml`
/// 2. Hardcoded defaults in the config struct's initializer
public enum SystemRuntimeOptions {
    /// Path to the user's configuration file.
    public static var defaultUserConfigPath: URL {
        let configHome: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configHome = xdg
        } else {
            configHome = NSHomeDirectory() + "/.config"
        }
        return URL(fileURLWithPath: configHome)
            .appendingPathComponent("container")
            .appendingPathComponent("runtime-config.toml")
    }

    /// The path to the config file within an application root directory.
    public static func configFileFromAppRoot(_ appRoot: URL) -> URL {
        appRoot
            .appendingPathComponent("config")
            .appendingPathComponent("runtime-config.toml")
    }

    /// Load configuration by decoding a TOML file.
    ///
    /// - Parameters:
    ///   - configFile: Full path to the TOML config file.
    /// - Returns: The decoded configuration. If the file does not exist, all values
    ///   fall back to the type's hardcoded defaults.
    public static func loadConfig<T: Codable & Sendable>(configFile: URL) throws -> T {
        let fm = FileManager.default
        let path = configFile.path(percentEncoded: false)
        guard fm.fileExists(atPath: path) else {
            do {
                return try TOMLDecoder().decode(T.self, from: Data("".utf8))
            } catch {
                throw ContainerizationError(.internalError, message: "failed to initialize default configuration: \(error)")
            }
        }
        do {
            let data = try Data(contentsOf: configFile)
            return try TOMLDecoder().decode(T.self, from: data)
        } catch {
            throw ContainerizationError(.invalidArgument, message: "failed to load configuration from '\(path)': \(error)")
        }
    }

    public static func copyConfigToAppRoot(
        appRoot: URL,
        userConfigPath: URL = defaultUserConfigPath,
    ) {
        let fm = FileManager.default

        if fm.fileExists(atPath: userConfigPath.path(percentEncoded: false)) {
            let configDir = appRoot.appendingPathComponent("config")
            let destPath = configDir.appendingPathComponent("runtime-config.toml")
            do {
                try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destPath.path(percentEncoded: false)) {
                    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destPath.path(percentEncoded: false))
                    try fm.removeItem(at: destPath)
                }
                try fm.copyItem(
                    at: URL(fileURLWithPath: userConfigPath.path(percentEncoded: false)),
                    to: destPath
                )
                try fm.setAttributes(
                    [.posixPermissions: 0o444],
                    ofItemAtPath: destPath.path(percentEncoded: false)
                )
                log.info("copied runtime config", metadata: ["dest": "\(destPath.path(percentEncoded: false))"])
            } catch {
                // If the config copy-ing fails, we will log an error but it is not fatal since we can utilize the fallback config.
                log.error("failed to copy runtime config to app root", metadata: ["error": "\(error)"])
            }
        }
    }
}
