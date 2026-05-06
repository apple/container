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

import Configuration
import ConfigurationTOML
import ContainerizationError
import Foundation
import SystemPackage

public protocol Initable {
    init()
}

public typealias LoadableConfiguration = Codable & Sendable & Initable

public protocol LoadablePluginConfiguration: LoadableConfiguration {
    static var pluginId: String { get }
}

public enum ConfigurationLoader {
    private static let configFilename = "runtime-config.toml"
    private static let configDirectory = "config"
    private static let READ_ONLY: Int = 0o444
    private static let READ_AND_WRITE: Int = 0o644

    /// Returns the configuration file path for a given base kind, resolving the base
    /// directory via `BaseConfigPath.basePath()` (env-driven, with fallbacks).
    ///
    /// Use `configurationFile(in:of:)` when you need to supply an explicit base —
    /// e.g. a CLI flag like `--app-root` that bypasses env lookup.
    ///
    /// - Parameter kind: The base directory role to resolve.
    public static func configurationFile(_ kind: PathUtils.BaseConfigPath) -> FilePath {
        configurationFile(in: kind.basePath(), of: kind)
    }

    /// Returns the configuration file path under an explicit base directory.
    ///
    /// Path shape depends on `kind`:
    /// - `.home`: `<base>/runtime-config.toml` (user source under `~/.config/container`)
    ///     - e.g. `~/.config/container/runtime-config.toml`
    /// - `.appRoot`: `<base>/config/runtime-config.toml` (read-only copy of user config)
    ///     - e.g. `~/Library/Application Support/com.apple.container/config/runtime-config.toml`
    /// - `.installRoot`: `<base>/etc/container/runtime-config.toml` (system defaults shipped with install)
    ///     - e.g. `/usr/local/etc/container/runtime-config.toml`
    ///
    /// - Parameters:
    ///   - base: Directory to resolve against.
    ///   - kind: Base directory role. Defaults to `.appRoot`.
    public static func configurationFile(
        in base: FilePath,
        of kind: PathUtils.BaseConfigPath = .appRoot
    ) -> FilePath {
        switch kind {
        case .home: base.appending(configFilename)
        case .appRoot: base.appending(configDirectory).appending(configFilename)
        case .installRoot: base.appending("etc/container").appending(configFilename)
        }
    }

    /// Default ordered TOML layers consumed by `load` and `loadForPlugin`:
    /// user config (`.appRoot`) followed by system defaults (`.installRoot`).
    public static func defaultConfigFiles() -> [FilePath] {
        [
            configurationFile(.appRoot),
            configurationFile(.installRoot),
        ]
    }

    /// Load the `ContainerSystemConfig` by layering TOML files with first-match-wins precedence.
    ///
    /// Providers are consulted in the order given — values from earlier files override
    /// later ones. The default order is user config (`<appRoot>/config/runtime-config.toml`)
    /// > system config (`<installRoot>/etc/container/config/runtime-config.toml`).
    ///
    /// An empty `configurationFiles` array falls back to `defaultConfigFiles()`.
    ///
    /// When a key is absent from every file, `ContainerSystemConfig.init(from:)` uses
    /// `decodeIfPresent` and falls back to the property's default value — "code defaults"
    /// are not a provider layer.
    ///
    /// Missing files are tolerated; malformed TOML still throws.
    ///
    /// - Parameter configurationFiles: Ordered TOML layers, highest precedence first.
    ///   Defaults to `defaultConfigFiles()`.
    /// - Returns: The decoded `ContainerSystemConfig`.
    /// - Throws: `ContainerizationError.invalidArgument` if any layer fails to load or decode.
    public static func load(
        configurationFiles: [FilePath] = defaultConfigFiles()
    ) async throws -> ContainerSystemConfig {
        try await loadAndDecode(
            ContainerSystemConfig.self,
            configurationFiles: configurationFiles,
            decodeErrorContext: "failed to decode configuration"
        )
    }

    /// Load a plugin-scoped configuration from the `[plugin.<P.pluginId>]` section of
    /// the layered TOML files.
    ///
    /// Uses the same layering and precedence rules as `load`, but scopes the snapshot
    /// to `plugin.<P.pluginId>` before decoding. A missing `[plugin.<P.pluginId>]`
    /// section falls back to `P()`.
    ///
    /// - Parameter configurationFiles: Ordered TOML layers, highest precedence first.
    ///   Defaults to `defaultConfigFiles()`.
    /// - Returns: The decoded plugin configuration, or `P()` if no files exist.
    /// - Throws: `ContainerizationError.invalidArgument` if `P.pluginId` is empty, a
    ///   layer fails to load, or the `[plugin.<P.pluginId>]` section is malformed.
    public static func loadForPlugin<P: LoadablePluginConfiguration>(
        configurationFiles: [FilePath] = defaultConfigFiles()
    ) async throws -> P {
        let id = P.pluginId
        guard !id.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "plugin id must not be empty")
        }
        return try await loadAndDecode(
            P.self,
            configurationFiles: configurationFiles,
            scope: ConfigKey("plugin.\(id)"),
            decodeErrorContext: "failed to decode plugin configuration for '\(id)'"
        )
    }

    /// Shared implementation for `load` and `loadForPlugin`. Builds TOML providers
    /// from `configurationFiles`, optionally scopes the snapshot, then decodes into `T`.
    /// Short-circuits to `T()` when every path is missing on disk.
    ///
    /// - Parameters:
    ///   - type: The concrete `LoadableConfiguration` type to decode.
    ///   - configurationFiles: Ordered TOML layers; empty falls back to `defaultConfigFiles()`.
    ///   - scope: Optional `ConfigKey` to scope the snapshot before decoding.
    ///   - decodeErrorContext: Prefix used in the `invalidArgument` error thrown on decode failure.
    private static func loadAndDecode<T: LoadableConfiguration>(
        _ type: T.Type,
        configurationFiles: [FilePath],
        scope: ConfigKey? = nil,
        decodeErrorContext: String
    ) async throws -> T {
        let paths = configurationFiles.isEmpty ? defaultConfigFiles() : configurationFiles
        let fm = FileManager.default
        if paths.allSatisfy({ !fm.fileExists(atPath: $0.string) }) {
            return T()
        }

        var providers: [FileProvider<TOMLSnapshot>] = []
        for path in paths {
            do {
                try providers.append(await FileProvider<TOMLSnapshot>(filePath: path, allowMissing: true))
            } catch {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "failed to load configuration from '\(path)': \(error)"
                )
            }
        }

        let reader = ConfigReader(providers: providers)
        let snapshot = scope.map { reader.snapshot().scoped(to: $0) } ?? reader.snapshot()
        do {
            return try ConfigSnapshotDecoder().decode(T.self, from: snapshot)
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "\(decodeErrorContext): \(error)"
            )
        }
    }

    /// Copies the user's runtime configuration into the app-root as a read-only snapshot.
    ///
    /// If `source` does not exist, this is a no-op. Otherwise, any existing destination
    /// is deleted and replaced with a fresh copy, which is then marked read-only.
    ///
    /// - Parameters:
    ///   - source: File to copy from. Defaults to `<home>/container/runtime-config.toml`.
    ///   - destination: Directory to copy into — the filename is appended automatically.
    ///     Defaults to `<appRoot>/config/runtime-config.toml`.
    public static func copyConfigurationToReadOnly(
        from source: FilePath? = nil,
        to destination: FilePath? = nil
    ) throws {
        let sourcePath = source ?? configurationFile(.home)
        let destBase = destination ?? PathUtils.BaseConfigPath.appRoot.basePath()
        let destPath = configurationFile(in: destBase)

        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath.string) else { return }

        let destDir = destPath.removingLastComponent()
        try fm.createDirectory(atPath: destDir.string, withIntermediateDirectories: true)

        if fm.fileExists(atPath: destPath.string) {
            try fm.setAttributes([.posixPermissions: READ_AND_WRITE], ofItemAtPath: destPath.string)
            try fm.removeItem(at: URL(filePath: destPath.string))
        }

        try fm.copyItem(
            at: URL(filePath: sourcePath.string),
            to: URL(filePath: destPath.string)
        )
        try fm.setAttributes([.posixPermissions: READ_ONLY], ofItemAtPath: destPath.string)
    }
}
