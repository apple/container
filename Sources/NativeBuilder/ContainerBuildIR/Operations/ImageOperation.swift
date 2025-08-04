//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import ContainerizationOCI
import Foundation

/// Represents base image operations (FROM in Dockerfile).
///
/// Design rationale:
/// - Handles both image pulls and scratch images
/// - Platform-aware for multi-arch support
/// - Supports image verification and policy
public struct ImageOperation: Operation, Hashable, Equatable {
    public static let operationKind = OperationKind.image
    public var operationKind: OperationKind { Self.operationKind }

    /// Image source
    public let source: ImageSource

    /// Target platform
    public let platform: Platform?

    /// Pull policy
    public let pullPolicy: PullPolicy

    /// Image verification
    public let verification: ImageVerification?

    /// Operation metadata
    public let metadata: OperationMetadata

    public init(
        source: ImageSource,
        platform: Platform? = nil,
        pullPolicy: PullPolicy = .ifNotPresent,
        verification: ImageVerification? = nil,
        metadata: OperationMetadata = OperationMetadata()
    ) {
        self.source = source
        self.platform = platform
        self.pullPolicy = pullPolicy
        self.verification = verification
        self.metadata = metadata
    }

    public func accept<V: OperationVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Image Source

/// Source of base image.
///
/// Design rationale:
/// - Supports registry images and scratch
/// - Extensible for future image sources
/// - Clear semantics for each source type
public enum ImageSource: Hashable, Sendable {
    /// Image from registry
    case registry(ImageReference)

    /// Empty image (FROM scratch)
    case scratch

    /// Local OCI layout
    case ociLayout(path: String, tag: String?)

    /// Tarball
    case tarball(path: String)
}

// MARK: - Pull Policy

/// Policy for pulling images.
///
/// Design rationale:
/// - Matches Kubernetes/Docker semantics
/// - Allows optimization vs freshness tradeoffs
public enum PullPolicy: String, Hashable, Sendable {
    /// Always pull
    case always

    /// Pull if not present locally
    case ifNotPresent

    /// Never pull (must exist locally)
    case never
}

// MARK: - Image Verification

/// Image verification requirements.
///
/// Design rationale:
/// - Supports multiple verification methods
/// - Extensible for new verification types
/// - Policy-based for enterprise requirements
public struct ImageVerification: Hashable, Sendable {
    /// Verification method
    public let method: VerificationMethod

    /// Required signatures
    public let requiredSignatures: Int

    /// Trusted keys/identities
    public let trustedKeys: Set<TrustedKey>

    public init(
        method: VerificationMethod,
        requiredSignatures: Int = 1,
        trustedKeys: Set<TrustedKey> = []
    ) {
        self.method = method
        self.requiredSignatures = requiredSignatures
        self.trustedKeys = trustedKeys
    }
}

/// Verification method.
public enum VerificationMethod: String, Hashable, Sendable {
    /// No verification
    case none

    /// Verify digest only
    case digest

    /// Cosign signatures
    case cosign

    /// Notary v2
    case notary

    /// In-toto attestations
    case intoto
}

/// Trusted key for verification.
public enum TrustedKey: Hashable, Sendable {
    /// Public key
    case publicKey(Data)

    /// Key ID (for key servers)
    case keyID(String)

    /// Certificate
    case certificate(Data)

    /// OIDC identity
    case oidcIdentity(issuer: String, subject: String)
}

// MARK: - Codable

extension ImageOperation: Codable {}
extension ImageSource: Codable {}
extension PullPolicy: Codable {}
extension ImageVerification: Codable {}
extension VerificationMethod: Codable {}
extension TrustedKey: Codable {}
