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

public protocol Initable {
    init()
}

public typealias LoadableConfiguration = Codable & Sendable & Initable

public enum ConfigurationLoader {
    private static let configFilename = "runtime-config.toml"
    private static let configDirectory = "config"
    private static let READ_ONLY: Int = 0o444
    private static let READ_AND_WRITE: Int = 0o644

    /// Returns the canonical configuration file path under an appRoot base directory:
    /// `<base>/config/runtime-config.toml`.
    public static func configurationFile(in base: FilePath) -> FilePath {
        base.appending(configDirectory).appending(configFilename)
    }

    /// Loads and decodes a TOML configuration file as type `T`.
    ///
    /// - Parameter configurationFile: Absolute path to the configuration file.
    ///   When `nil`, falls back to
    ///   `configurationFile(in: PathUtils.BaseConfigPath.appRoot.basePath())`.
    /// - Returns: A decoded value of type `T`, or a default-initialized `T` if the
    ///   configuration file does not exist.
    public static func load<T: LoadableConfiguration>(configurationFile: FilePath? = nil) throws -> T {
        let path = configurationFile ?? Self.configurationFile(in: PathUtils.BaseConfigPath.appRoot.basePath())
        guard FileManager.default.fileExists(atPath: path.string) else {
            return T()
        }
        do {
            let data = try Data(contentsOf: URL(filePath: path.string))
            return try TOMLDecoder().decode(T.self, from: data)
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "failed to load configuration from '\(path)': \(error)"
            )
        }
    }

    /// Copies a TOML configuration file into a read-only destination under an appRoot base.
    ///
    /// - Parameters:
    ///   - source: The file to copy. When `nil`, defaults to
    ///     `<home>/container/runtime-config.toml`. If the source does not exist,
    ///     this is a no-op.
    ///   - destination: Base directory under which the file is written at
    ///     `<destination>/config/runtime-config.toml`. When `nil`, falls back to
    ///     `PathUtils.BaseConfigPath.appRoot.basePath()`. The destination file is written
    ///     with `READ_ONLY` (`0o444`) permissions.
    public static func copyConfigurationToReadOnly(
        from source: FilePath? = nil,
        to destination: FilePath? = nil
    ) throws {
        let source =
            source
            ?? PathUtils.BaseConfigPath.home.basePath()
            .appending(configFilename)
        let destinationFile = Self.configurationFile(in: destination ?? PathUtils.BaseConfigPath.appRoot.basePath())
        do {
            let fm = FileManager.default
            guard fm.fileExists(atPath: source.string) else { return }

            let destDir = destinationFile.removingLastComponent()
            try fm.createDirectory(
                atPath: destDir.string,
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: destinationFile.string) {
                try fm.setAttributes(
                    [.posixPermissions: READ_AND_WRITE],
                    ofItemAtPath: destinationFile.string
                )
                try fm.removeItem(at: URL(filePath: destinationFile.string))
            }
            try fm.copyItem(
                at: URL(filePath: source.string),
                to: URL(filePath: destinationFile.string)
            )
            try fm.setAttributes(
                [.posixPermissions: READ_ONLY],
                ofItemAtPath: destinationFile.string
            )
        } catch {
            throw ContainerizationError(
                .invalidState, message: "Failed to copy user TOML to AppRoot `\(error)`")
        }
    }
}
