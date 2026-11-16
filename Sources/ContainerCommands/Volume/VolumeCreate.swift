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

import ArgumentParser
import ContainerAPIClient
import ContainerResource
import Foundation

extension Application.VolumeCommand {
    public struct VolumeCreate: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new volume"
        )

        @Option(name: .customLong("driver"), help: "Volume driver: local, smb, or nfs (default: local; smb and nfs are experimental)")
        var driver: String = "local"

        @Option(name: .customLong("label"), help: "Set metadata for a volume")
        var labels: [String] = []

        @Option(name: .customLong("opt"), help: "Set driver specific options")
        var driverOpts: [String] = []

        @Flag(name: .customLong("password-stdin"), help: "Take the SMB password from stdin (smb driver only)")
        var passwordStdin: Bool = false

        @Option(name: .short, help: "Size of the volume in bytes, with optional K, M, G, T, or P suffix")
        var size: String?

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Volume name")
        var name: String

        public init() {}

        public func run() async throws {
            var parsedDriverOpts = Utility.parseKeyValuePairs(driverOpts)
            let parsedLabels = Utility.parseKeyValuePairs(labels)

            // If --size is specified, add it to driver options
            if let size = size {
                parsedDriverOpts["size"] = size
            }

            if passwordStdin {
                try Self.validatePasswordStdin(driver: driver, driverOpts: parsedDriverOpts)
                parsedDriverOpts[MountOptionValidator.passwordKey] = try Self.password(
                    fromStdin: try FileHandle.standardInput.readToEnd()
                )
            }

            // The server validates the options too, but checking here fails fast with a CLI error.
            if driver == "smb" || driver == "nfs" {
                do {
                    if driver == "smb" {
                        try MountOptionValidator.validateSMBOptions(parsedDriverOpts, allowPassword: true)
                    } else {
                        try MountOptionValidator.validateNFSOptions(parsedDriverOpts)
                    }
                } catch let violation as MountOptionValidator.Violation {
                    throw ValidationError(violation.description)
                }
            }

            let volume = try await ClientVolume.create(
                name: name,
                driver: driver,
                driverOpts: parsedDriverOpts,
                labels: parsedLabels
            )
            print(volume.name)
        }

        /// Checks that `--password-stdin` can be used with the given driver and options.
        ///
        /// This runs before stdin is read, so a mistake in the command line is reported without
        /// waiting for input.
        static func validatePasswordStdin(driver: String, driverOpts: [String: String]) throws {
            guard driver == "smb" else {
                throw ValidationError("--password-stdin is only supported with --driver smb")
            }
            guard driverOpts[MountOptionValidator.passwordKey] == nil else {
                throw ValidationError("--password-stdin cannot be combined with --opt \(MountOptionValidator.passwordKey)=")
            }
            guard let username = driverOpts["username"], !username.isEmpty else {
                throw ValidationError("--password-stdin requires --opt username=<user>")
            }
        }

        /// Returns the password in the data read from stdin, without its trailing line ending.
        ///
        /// Only trailing newlines and carriage returns are removed, so `echo` and `printf` both
        /// work. Any other whitespace is left for the option validator to reject, rather than
        /// silently changing the password.
        static func password(fromStdin data: Data?) throws -> String {
            guard let data, var password = String(data: data, encoding: .utf8) else {
                throw ValidationError("failed to read the password from stdin")
            }
            while let last = password.unicodeScalars.last, last == "\n" || last == "\r" {
                password.unicodeScalars.removeLast()
            }
            guard !password.isEmpty else {
                throw ValidationError("the password read from stdin is empty")
            }
            return password
        }
    }
}
