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
import ContainerizationOCI
import Foundation
import Logging

/// Resolves the default platform from the `CONTAINER_DEFAULT_PLATFORM` environment variable.
///
/// When set, this variable overrides the native platform as the default for commands
/// that support `--platform`. Explicit `--platform` flags always take precedence.
public enum DefaultPlatform {
    /// The name of the environment variable checked for a default platform.
    public static let environmentVariable = "CONTAINER_DEFAULT_PLATFORM"

    /// Reads and parses the `CONTAINER_DEFAULT_PLATFORM` environment variable.
    ///
    /// When a valid platform is found and a logger is provided, a warning is emitted
    /// to inform the user that the environment variable is being used.
    ///
    /// - Parameters:
    ///   - environment: The environment dictionary to read from. Defaults to the current process environment.
    ///   - log: An optional logger. When provided, a warning is logged if the environment variable is active.
    /// - Returns: The parsed platform, or `nil` if the variable is not set or empty.
    /// - Throws: ContainerizationError if the variable is set but contains an invalid platform string.
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: Logger? = nil
    ) throws -> ContainerizationOCI.Platform? {
        guard let value = environment[environmentVariable],
            !value.isEmpty
        else {
            return nil
        }
        let platform: ContainerizationOCI.Platform
        do {
            platform = try ContainerizationOCI.Platform(from: value)
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid platform \"\(value)\" in \(environmentVariable) environment variable",
                cause: error
            )
        }
        logNotice(platform, log: log)
        return platform
    }

    /// Resolves the platform for commands where `--os` and `--arch` are optional (image pull, push, save).
    ///
    /// Precedence: `--platform` > `--os`/`--arch` > `CONTAINER_DEFAULT_PLATFORM` > `nil`.
    ///
    /// - Parameters:
    ///   - platform: The value of the `--platform` flag, if provided.
    ///   - os: The value of the `--os` flag, if provided.
    ///   - arch: The value of the `--arch` flag, if provided.
    ///   - environment: The environment dictionary to read from. Defaults to the current process environment.
    ///   - log: An optional logger for environment variable notices.
    /// - Returns: The resolved platform, or `nil` if no platform information is available.
    /// - Throws: ContainerizationError if a platform string (from flags or environment) is invalid.
    public static func resolve(
        platform: String?,
        os: String?,
        arch: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: Logger? = nil
    ) throws -> ContainerizationOCI.Platform? {
        if let platform {
            return try ContainerizationOCI.Platform(from: platform)
        }
        if let arch {
            return try ContainerizationOCI.Platform(from: "\(os ?? "linux")/\(arch)")
        }
        if let os {
            return try ContainerizationOCI.Platform(from: "\(os)/\(arch ?? Arch.hostArchitecture().rawValue)")
        }
        return try fromEnvironment(environment: environment, log: log)
    }

    /// Resolves the platform for commands where `--os` and `--arch` have defaults (run, create).
    ///
    /// Precedence: `--platform` > `CONTAINER_DEFAULT_PLATFORM` > `--os`/`--arch` defaults.
    ///
    /// - Parameters:
    ///   - platform: The value of the `--platform` flag, if provided.
    ///   - os: The default OS value (always present).
    ///   - arch: The default architecture value (always present).
    ///   - environment: The environment dictionary to read from. Defaults to the current process environment.
    ///   - log: An optional logger for environment variable notices.
    /// - Returns: The resolved platform. Always returns a value since os/arch defaults are provided.
    /// - Throws: ContainerizationError if a platform string (from flags or environment) is invalid.
    public static func resolveWithDefaults(
        platform: String?,
        os: String,
        arch: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: Logger? = nil
    ) throws -> ContainerizationOCI.Platform {
        if let platform {
            return try Parser.platform(from: platform)
        }
        if let envPlatform = try fromEnvironment(environment: environment, log: log) {
            return envPlatform
        }
        return Parser.platform(os: os, arch: arch)
    }

    private static func logNotice(_ platform: ContainerizationOCI.Platform, log: Logger?) {
        guard let log else { return }
        log.warning(
            "using platform from environment variable",
            metadata: [
                "platform": "\(platform.description)",
                "variable": "\(environmentVariable)",
            ]
        )
    }
}
