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

import ContainerAPIClient
import ContainerizationOS
import Foundation

/// A credential stored for a volume, such as the username and password of an SMB share.
public struct VolumeCredential: Sendable, Equatable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Stores the secrets that a volume needs at mount time, keyed by volume name.
///
/// The password of an SMB volume is kept here rather than in `VolumeConfiguration.options`, so it
/// is never written to the volume store, the container bundle, or shown by `volume inspect`. The
/// API server writes the secret when the volume is created, reads it back when a container that
/// mounts the volume is bootstrapped, and removes it when the volume is deleted.
public protocol VolumeCredentialStore: Sendable {
    /// Saves the credential for a volume, replacing any existing credential.
    func save(volume: String, credential: VolumeCredential) throws

    /// Returns the credential for a volume, or nil if none is stored.
    func lookup(volume: String) throws -> VolumeCredential?

    /// Removes the credential for a volume. Removing a credential that does not exist is not an error.
    func delete(volume: String) throws
}

/// A `VolumeCredentialStore` backed by the macOS keychain.
///
/// Items are stored as internet passwords under `Constants.volumeKeychainID`, with the volume name as
/// the server attribute, which keeps them apart from the registry credentials that `container registry
/// login` stores under `Constants.keychainID`.
public struct KeychainVolumeCredentialStore: VolumeCredentialStore {
    private let securityDomain: String

    public init(securityDomain: String = Constants.volumeKeychainID) {
        self.securityDomain = securityDomain
    }

    public func save(volume: String, credential: VolumeCredential) throws {
        try KeychainQuery().save(
            securityDomain: self.securityDomain,
            hostname: volume,
            username: credential.username,
            password: credential.password
        )
    }

    public func lookup(volume: String) throws -> VolumeCredential? {
        guard let result = try KeychainQuery().get(securityDomain: self.securityDomain, hostname: volume) else {
            return nil
        }
        return VolumeCredential(username: result.username, password: result.password)
    }

    public func delete(volume: String) throws {
        try KeychainQuery().delete(securityDomain: self.securityDomain, hostname: volume)
    }
}
