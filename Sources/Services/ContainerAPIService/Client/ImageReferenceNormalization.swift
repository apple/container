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

import ContainerPersistence
import Containerization
import ContainerizationOCI

/// How a legacy short-name image reference relates to the fully-qualified
/// reference current releases store.
///
/// Releases before fully-qualified tagging wrote the name as typed
/// (`finlay-ledger:latest`). A later build of the same tag is stored as
/// `docker.io/library/finlay-ledger:latest`, which does not replace the old
/// key. These helpers find those legacy keys so they can be moved onto the
/// fully-qualified name before the rebuild overwrites it.
public enum ImageReferenceNormalization {
    public struct Plan: Equatable, Sendable {
        /// Legacy reference to copy onto the fully-qualified key before a
        /// rebuild overwrites that key. Nil when the key already exists, or
        /// when the only legacy reference is one the caller still has to read.
        public var renameFrom: String?

        /// Legacy references that denote the fully-qualified image and should
        /// be removed once that key holds the image to keep.
        public var drop: [String]

        public init(renameFrom: String?, drop: [String]) {
            self.renameFrom = renameFrom
            self.drop = drop
        }
    }

    /// One stored image, reduced to the names lookup and normalization compare.
    struct Candidate: Equatable, Sendable {
        var reference: String
        var annotatedName: String?
    }

    /// References that normalize to `fullyQualified` but are stored under a
    /// different string.
    public static func plan(
        storedReferences: [String],
        fullyQualified: String,
        preserving: String? = nil,
        containerSystemConfig: ContainerSystemConfig
    ) -> Plan {
        let aliases = storedReferences.filter { reference in
            reference != fullyQualified
                && referencesMatch(reference, fullyQualified, containerSystemConfig: containerSystemConfig)
        }
        let renameFrom: String?
        if storedReferences.contains(fullyQualified) {
            renameFrom = nil
        } else {
            renameFrom = aliases.first { alias in
                guard let preserving else {
                    return true
                }
                return alias != preserving
            }
        }
        return Plan(renameFrom: renameFrom, drop: aliases)
    }

    /// Legacy references to drop because the fully-qualified form is already stored.
    ///
    /// A short name on its own is left in place. It is only a shadow once a
    /// rebuild has written the fully-qualified key beside it.
    public static func legacyShadows(
        storedReferences: [String],
        containerSystemConfig: ContainerSystemConfig
    ) -> [String] {
        let present = Set(storedReferences)
        return storedReferences.filter { reference in
            guard let fullyQualified = try? ClientImage.normalizeReference(reference, containerSystemConfig: containerSystemConfig) else {
                return false
            }
            return fullyQualified != reference && present.contains(fullyQualified)
        }
    }

    /// Image to use for `reference`.
    ///
    /// A short name and its fully-qualified form match. When both are stored,
    /// the fully-qualified entry wins so the pre-upgrade image cannot shadow a rebuild.
    static func select(
        reference: String,
        candidates: [Candidate],
        containerSystemConfig: ContainerSystemConfig
    ) throws -> Candidate? {
        let normalizedReference = try ClientImage.normalizeReference(reference, containerSystemConfig: containerSystemConfig)
        let parsed = try Reference.parse(reference)
        parsed.normalize()
        let withDefaultTag = parsed.description

        let annotated = candidates.filter { candidate in
            guard let annotatedName = candidate.annotatedName else {
                return false
            }
            return annotatedName == withDefaultTag
                || annotatedName == reference
                || annotatedName == normalizedReference
                || referencesMatch(annotatedName, normalizedReference, containerSystemConfig: containerSystemConfig)
        }
        if annotated.count == 1 {
            return annotated.first
        }
        if annotated.count > 1 {
            if let fullyQualified = annotated.first(where: { $0.reference == normalizedReference }) {
                return fullyQualified
            }
            if let typed = annotated.first(where: { $0.reference == withDefaultTag || $0.reference == reference }) {
                return typed
            }
        }

        let referenced = candidates.filter { candidate in
            referencesMatch(candidate.reference, normalizedReference, containerSystemConfig: containerSystemConfig)
        }
        if referenced.count == 1 {
            return referenced.first
        }
        return referenced.first(where: { $0.reference == normalizedReference }) ?? referenced.first
    }

    /// Whether two references name the same image after registry and tag normalization.
    static func referencesMatch(
        _ lhs: String,
        _ rhs: String,
        containerSystemConfig: ContainerSystemConfig
    ) -> Bool {
        if lhs == rhs {
            return true
        }
        guard
            let left = try? ClientImage.normalizeReference(lhs, containerSystemConfig: containerSystemConfig),
            let right = try? ClientImage.normalizeReference(rhs, containerSystemConfig: containerSystemConfig)
        else {
            return false
        }
        return left == right
    }
}
