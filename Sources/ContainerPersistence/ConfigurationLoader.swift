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

public protocol Initable {
    init()
}

private let log = Logger(label: "ConfigurationLoader")

public enum ConfigurationLoader {
    private static let configFilename = "runtime-config.toml"

    public static func load<T: Codable & Sendable & Initable>() throws -> T {
        let path = PathUtils.BaseConfigPath.appRoot.basePath()
            .appending("config")
            .appending(configFilename)
        return try load(configFile: path)
    }

    static func load<T: Codable & Sendable & Initable>(configFile: FilePath) throws -> T {
        guard FileManager.default.fileExists(atPath: configFile.string) else {
            return T()
        }
        do {
            let data = try Data(contentsOf: URL(filePath: configFile.string))
            return try TOMLDecoder().decode(T.self, from: data)
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "failed to load configuration from '\(configFile)': \(error)"
            )
        }
    }

    public static func copyConfigToAppRoot() throws {
        let source = PathUtils.BaseConfigPath.home.basePath()
            .appending(configFilename)
        let destination = PathUtils.BaseConfigPath.appRoot.basePath()
            .appending("config")
            .appending(configFilename)
        do {
            try copyConfigToAppRoot(from: source, to: destination)
        } catch {
            throw ContainerizationError(
                .invalidState, message: "Failed to copy user TOML to AppRoot `\(error)`")
        }
    }

    static func copyConfigToAppRoot(from source: FilePath, to destination: FilePath) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.string) else { return }

        let destDir = destination.removingLastComponent()
        try fm.createDirectory(
            atPath: destDir.string,
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destination.string) {
            try fm.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: destination.string
            )
            try fm.removeItem(at: URL(filePath: destination.string))
        }
        try fm.copyItem(
            at: URL(filePath: source.string),
            to: URL(filePath: destination.string)
        )
        try fm.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: destination.string
        )
    }
}
