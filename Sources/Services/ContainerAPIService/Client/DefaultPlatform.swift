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

/// Resolves the default platform from the `CONTAINER_DEFAULT_PLATFORM` environment variable.
///
/// When set, this variable overrides the native platform as the default for commands
/// that support `--platform`. Explicit `--platform` flags always take precedence.
public enum DefaultPlatform {
    public static let environmentVariable = "CONTAINER_DEFAULT_PLATFORM"

    /// Reads and parses the `CONTAINER_DEFAULT_PLATFORM` environment variable.
    ///
    /// - Parameter environment: The environment dictionary to read from. Defaults to the process environment.
    /// - Returns: The parsed platform, or `nil` if the variable is not set or empty.
    /// - Throws: `ContainerizationError` if the variable is set but contains an invalid platform string.
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ContainerizationOCI.Platform? {
        guard let value = environment[environmentVariable],
            !value.isEmpty
        else {
            return nil
        }
        do {
            return try ContainerizationOCI.Platform(from: value)
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid platform \"\(value)\" in \(environmentVariable) environment variable",
                cause: error
            )
        }
    }

    /// Prints a notice to stderr indicating that the environment variable is being used.
    public static func printNotice(_ platform: ContainerizationOCI.Platform) {
        let message = "Notice: Using platform \"\(platform.description)\" from \(environmentVariable)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    /// Resolves the platform for commands where `--os` and `--arch` are optional (image pull, push, save).
    ///
    /// Precedence: `--platform` > `--os`/`--arch` > `CONTAINER_DEFAULT_PLATFORM` > nil
    public static func resolve(
        platform: String?,
        os: String?,
        arch: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
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
        if let envPlatform = try fromEnvironment(environment: environment) {
            printNotice(envPlatform)
            return envPlatform
        }
        return nil
    }

    /// Resolves the platform for commands where `--os` and `--arch` have defaults (run, create).
    ///
    /// Precedence: `--platform` > `CONTAINER_DEFAULT_PLATFORM` > `--os`/`--arch` defaults
    public static func resolveWithDefaults(
        platform: String?,
        os: String,
        arch: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ContainerizationOCI.Platform {
        if let platform {
            return try Parser.platform(from: platform)
        }
        if let envPlatform = try fromEnvironment(environment: environment) {
            printNotice(envPlatform)
            return envPlatform
        }
        return Parser.platform(os: os, arch: arch)
    }
}
