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
import SystemPackage
import TOML

public enum ConfigurationLoader {
    public static func load<T: Codable & Sendable>(configFile: FilePath) throws -> T {
        let path = configFile.string
        guard FileManager.default.fileExists(atPath: path) else {
            do {
                return try TOMLDecoder().decode(T.self, from: Data("".utf8))
            } catch {
                throw ContainerizationError(.internalError, message: "failed to initialize default configuration: \(error)")
            }
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try TOMLDecoder().decode(T.self, from: data)
        } catch {
            throw ContainerizationError(.invalidArgument, message: "failed to load configuration from '\(path)': \(error)")
        }
    }

    public static func copyConfigToAppRoot(
        appRoot: URL,
        userConfigPath: FilePath? = nil
    ) throws {
        let fm = FileManager.default
        let source: FilePath
        if let provided = userConfigPath {
            source = provided
            guard fm.fileExists(atPath: source.string) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "user config file not found at '\(source.string)'"
                )
            }
        } else {
            guard let resolved = UserConfiguration.resolve(from: .home, relativePath: "config.toml") else {
                return
            }
            source = resolved
        }

        let configDir = appRoot.appendingPathComponent("config")
        let destPath = configDir.appendingPathComponent("config.toml")
        do {
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destPath.path(percentEncoded: false)) {
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destPath.path(percentEncoded: false))
                try fm.removeItem(at: destPath)
            }
            try fm.copyItem(
                at: URL(fileURLWithPath: source.string),
                to: destPath
            )
            try fm.setAttributes(
                [.posixPermissions: 0o444],
                ofItemAtPath: destPath.path(percentEncoded: false)
            )
        } catch {
            throw ContainerizationError(.internalError, message: "failed to copy runtime config to app root: \(error)")
        }
    }
}
