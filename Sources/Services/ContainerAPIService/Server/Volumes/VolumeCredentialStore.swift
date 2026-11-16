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
import Security

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

/// An error from `KeychainVolumeCredentialStore`.
public enum KeychainVolumeCredentialStoreError: Error, Equatable, CustomStringConvertible {
    /// The keychain is locked, or its access list does not let this executable use the item, and
    /// the store may not ask the user to resolve either.
    case interactionRequired(status: OSStatus)

    /// User interaction could not be turned off, so the keychain was not queried.
    case cannotDisableUserInteraction(status: OSStatus)

    public var description: String {
        switch self {
        case .interactionRequired(let status):
            return
                "the keychain is locked, or it does not allow this build of container to use the item (status \(status)); "
                + "unlock the login keychain, or delete and recreate the volume"
        case .cannotDisableUserInteraction(let status):
            return "cannot turn off keychain user interaction (status \(status))"
        }
    }
}

/// A `VolumeCredentialStore` backed by the macOS keychain.
///
/// Items are stored as internet passwords under `Constants.volumeKeychainID`, with the volume name as
/// the server attribute, which keeps them apart from the registry credentials that `container registry
/// login` stores under `Constants.keychainID`.
///
/// The store never asks the user for anything. The API server calls it while it holds the locks that
/// serialize container and volume operations, so a keychain dialog (to unlock the keychain, or to
/// approve an executable that the item's access list does not trust, such as a rebuilt or re-signed
/// API server) would stall every one of those operations until someone answered it. Instead, such a
/// request fails with `KeychainVolumeCredentialStoreError.interactionRequired`.
///
/// - Important: The first use of the store turns off keychain user interaction for the whole process.
public struct KeychainVolumeCredentialStore: VolumeCredentialStore {
    /// The statuses the keychain returns in place of a dialog once user interaction is off.
    private static let interactionRequiredStatuses: Set<OSStatus> = [errSecAuthFailed, errSecInteractionNotAllowed]

    /// The result of turning off keychain user interaction for the process, which happens once.
    ///
    /// The items live in the file-based keychain, where a per-query `kSecUseAuthenticationUI` has no
    /// effect; `SecKeychainSetUserInteractionAllowed` is the only switch that keychain honors.
    private static let disableUserInteractionStatus: OSStatus = SecKeychainSetUserInteractionAllowed(false)

    private let securityDomain: String

    public init(securityDomain: String = Constants.volumeKeychainID) {
        self.securityDomain = securityDomain
    }

    public func save(volume: String, credential: VolumeCredential) throws {
        try Self.withoutUserInteraction {
            try KeychainQuery().save(
                securityDomain: self.securityDomain,
                hostname: volume,
                username: credential.username,
                password: credential.password
            )
        }
    }

    public func lookup(volume: String) throws -> VolumeCredential? {
        try Self.withoutUserInteraction {
            guard let result = try KeychainQuery().get(securityDomain: self.securityDomain, hostname: volume) else {
                return nil
            }
            return VolumeCredential(username: result.username, password: result.password)
        }
    }

    public func delete(volume: String) throws {
        try Self.withoutUserInteraction {
            try KeychainQuery().delete(securityDomain: self.securityDomain, hostname: volume)
        }
    }

    /// Runs a keychain operation that must fail rather than show a dialog.
    private static func withoutUserInteraction<T>(_ operation: () throws -> T) throws -> T {
        guard Self.disableUserInteractionStatus == errSecSuccess else {
            throw KeychainVolumeCredentialStoreError.cannotDisableUserInteraction(status: Self.disableUserInteractionStatus)
        }
        do {
            return try operation()
        } catch KeychainQuery.Error.unhandledError(let status) where Self.interactionRequiredStatuses.contains(status) {
            throw KeychainVolumeCredentialStoreError.interactionRequired(status: status)
        }
    }
}
