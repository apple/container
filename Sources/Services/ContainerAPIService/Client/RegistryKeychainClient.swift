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

import ContainerResource
import ContainerXPC
import ContainerizationOCI
import ContainerizationOS
import Foundation

/// A  client for managing registry credentials.
public struct RegistryKeychainClient {
    private let keychain: KeychainHelper

    /// Creates a a new instance using the default registry keychain domain.
    public init() {
        self.keychain = KeychainHelper(securityDomain: Constants.keychainID)
    }

    /// Returns all registry credentials stored in the keychain.
    /// - Returns: An array of `RegistryResource` values representing saved registry entries.
    /// - Throws: An error if the keychain query fails.
    public func list() async throws -> [RegistryResource] {
        let registries = try keychain.list()
        return registries.map { RegistryResource(from: $0) }
    }

    /// Stores credentials for a registry in the keychain.
    /// - Parameters:
    ///   - hostname: The registry hostname.
    ///   - username: The username for authentication.
    ///   - password: The password for authentication.
    /// - Throws: An error if the credentials cannot be saved to the keychain.
    public func login(hostname: String, username: String, password: String) async throws {
        try keychain.save(hostname: hostname, username: username, password: password)
    }

    /// Removes stored credentials for a registry from the keychain.
    /// - Parameter hostname: The registry hostname.
    /// - Throws: An error if the credentials cannot be removed.
    public func logout(hostname: String) async throws {
        try keychain.delete(hostname: hostname)
    }

    /// Prompts the user to enter a registry username.
    /// - Parameter hostname: The registry hostname being authenticated.
    /// - Returns: The username entered by the user.
    /// - Throws: An error if input cannot be read.
    public func userPrompt(hostname: String) async throws -> String {
        try keychain.userPrompt(hostname: hostname)
    }

    /// Prompts the user to enter a registry password.
    /// - Returns: The password entered by the user.
    /// - Throws: An error if input cannot be read.
    public func passwordPrompt() async throws -> String {
        try keychain.passwordPrompt()
    }
}
