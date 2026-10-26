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
import Testing

@testable import ContainerAPIClient

struct ImageReferenceNormalizationTests {
    private let config = ContainerSystemConfig()
    private let fullyQualified = "docker.io/library/finlay-ledger:latest"
    private let legacy = "finlay-ledger:latest"

    private func candidate(_ reference: String, annotation: String? = nil) -> ImageReferenceNormalization.Candidate {
        ImageReferenceNormalization.Candidate(reference: reference, annotatedName: annotation ?? reference)
    }

    private func digestReference(_ name: String, character: Character = "a") -> String {
        "\(name)@sha256:" + String(repeating: character, count: 64)
    }

    @Test func shortNameIsRenamedOntoTheFullyQualifiedReference() {
        let plan = ImageReferenceNormalization.plan(
            storedReferences: [legacy, "ghcr.io/example/other:latest"],
            fullyQualified: fullyQualified,
            containerSystemConfig: config
        )

        #expect(plan.renameFrom == legacy)
        #expect(plan.drop == [legacy])
    }

    @Test func existingFullyQualifiedReferenceIsNotReplacedByTheLegacyImage() {
        let plan = ImageReferenceNormalization.plan(
            storedReferences: [fullyQualified, legacy],
            fullyQualified: fullyQualified,
            containerSystemConfig: config
        )

        #expect(plan.renameFrom == nil)
        #expect(plan.drop == [legacy])
    }

    @Test func canonicalDockerLibraryReferenceNeedsNoMigration() {
        let plan = ImageReferenceNormalization.plan(
            storedReferences: [fullyQualified, "ghcr.io/example/other:latest"],
            fullyQualified: fullyQualified,
            containerSystemConfig: config
        )

        #expect(plan.renameFrom == nil)
        #expect(plan.drop.isEmpty)
    }

    @Test func preservedSourceIsNotCopiedBeforeItIsRead() {
        let plan = ImageReferenceNormalization.plan(
            storedReferences: [legacy, "finlay-ledger"],
            fullyQualified: fullyQualified,
            preserving: legacy,
            containerSystemConfig: config
        )

        #expect(plan.renameFrom == "finlay-ledger")
        #expect(plan.drop == [legacy, "finlay-ledger"])
    }

    @Test func namespacedAndCustomRegistryNamesNormalizeWithoutALibraryPrefix() {
        let namespaced = ImageReferenceNormalization.plan(
            storedReferences: ["team/app:1.2"],
            fullyQualified: "docker.io/team/app:1.2",
            containerSystemConfig: config
        )
        #expect(namespaced.renameFrom == "team/app:1.2")
        #expect(namespaced.drop == ["team/app:1.2"])

        let custom = ContainerSystemConfig(registry: RegistryConfig(domain: "example.com"))
        let planned = ImageReferenceNormalization.plan(
            storedReferences: ["app:latest"],
            fullyQualified: "example.com/app:latest",
            containerSystemConfig: custom
        )
        #expect(planned.renameFrom == "app:latest")
        #expect(planned.drop == ["app:latest"])
    }

    @Test func taglessShortNameIsEquivalentToExplicitLatest() {
        let tagless = "finlay-ledger"
        let plan = ImageReferenceNormalization.plan(
            storedReferences: [tagless],
            fullyQualified: fullyQualified,
            containerSystemConfig: config
        )

        #expect(plan.renameFrom == tagless)
        #expect(plan.drop == [tagless])
        #expect(
            ImageReferenceNormalization.legacyShadows(
                storedReferences: [tagless, fullyQualified],
                containerSystemConfig: config
            ) == [tagless]
        )
    }

    @Test func registryHostWithPortUsesTheConfiguredRegistry() {
        let local = ContainerSystemConfig(registry: RegistryConfig(domain: "localhost:5000"))
        let fullyQualifiedLocal = "localhost:5000/app:tag"
        let localPlan = ImageReferenceNormalization.plan(
            storedReferences: ["app:tag"],
            fullyQualified: fullyQualifiedLocal,
            containerSystemConfig: local
        )
        #expect(localPlan.renameFrom == "app:tag")
        #expect(localPlan.drop == ["app:tag"])

        let differentRegistryPlan = ImageReferenceNormalization.plan(
            storedReferences: ["app:tag"],
            fullyQualified: fullyQualifiedLocal,
            containerSystemConfig: config
        )
        #expect(differentRegistryPlan.renameFrom == nil)
        #expect(differentRegistryPlan.drop.isEmpty)
    }

    @Test func unrelatedAndDigestReferencesAreLeftAlone() {
        let digest = "app@sha256:" + String(repeating: "a", count: 64)
        let plan = ImageReferenceNormalization.plan(
            storedReferences: ["ghcr.io/example/app:latest", digest, config.vminit.image],
            fullyQualified: "docker.io/library/app:latest",
            containerSystemConfig: config
        )

        #expect(plan.renameFrom == nil)
        #expect(plan.drop.isEmpty)
    }

    @Test func digestReferencesAreNotLegacyAliases() {
        let shortDigest = digestReference("app")
        let fullyQualifiedDigest = digestReference("docker.io/library/app")
        let plan = ImageReferenceNormalization.plan(
            storedReferences: [shortDigest],
            fullyQualified: fullyQualifiedDigest,
            containerSystemConfig: config
        )

        #expect(plan.renameFrom == nil)
        #expect(plan.drop.isEmpty)
        #expect(
            ImageReferenceNormalization.legacyShadows(
                storedReferences: [shortDigest, fullyQualifiedDigest],
                containerSystemConfig: config
            ).isEmpty
        )
    }

    @Test func shadowsAreOnlyShortNamesBesideTheFullyQualifiedImage() {
        #expect(
            ImageReferenceNormalization.legacyShadows(
                storedReferences: [legacy, fullyQualified, "other:latest"],
                containerSystemConfig: config
            ) == [legacy]
        )
        #expect(
            ImageReferenceNormalization.legacyShadows(
                storedReferences: [legacy],
                containerSystemConfig: config
            ).isEmpty
        )
        #expect(
            ImageReferenceNormalization.legacyShadows(
                storedReferences: ["docker.io/finlay-ledger:latest", fullyQualified],
                containerSystemConfig: config
            ) == ["docker.io/finlay-ledger:latest"]
        )
    }

    @Test func lookupPrefersTheFullyQualifiedImageOverTheLegacyShortName() throws {
        let legacyImage = candidate(legacy)
        let rebuilt = candidate(fullyQualified)
        let selected = try ImageReferenceNormalization.select(
            reference: legacy,
            candidates: [legacyImage, rebuilt],
            containerSystemConfig: config
        )
        #expect(selected == rebuilt)

        let reversed = try ImageReferenceNormalization.select(
            reference: fullyQualified,
            candidates: [rebuilt, legacyImage],
            containerSystemConfig: config
        )
        #expect(reversed == rebuilt)
    }

    @Test func lookupFindsEitherFormWhenOnlyOneIsStored() throws {
        let legacyImage = candidate(legacy, annotation: legacy)
        let byShortName = try ImageReferenceNormalization.select(
            reference: legacy,
            candidates: [legacyImage],
            containerSystemConfig: config
        )
        #expect(byShortName == legacyImage)

        let rebuilt = candidate(fullyQualified, annotation: fullyQualified)
        let byQualifiedName = try ImageReferenceNormalization.select(
            reference: legacy,
            candidates: [rebuilt],
            containerSystemConfig: config
        )
        #expect(byQualifiedName == rebuilt)

        let qualifiedQuery = try ImageReferenceNormalization.select(
            reference: fullyQualified,
            candidates: [legacyImage],
            containerSystemConfig: config
        )
        #expect(qualifiedQuery == legacyImage)
    }

    @Test func lookupIgnoresAnUnrelatedImage() throws {
        let other = candidate("ghcr.io/example/other:latest")
        let selected = try ImageReferenceNormalization.select(
            reference: legacy,
            candidates: [other],
            containerSystemConfig: config
        )
        #expect(selected == nil)
    }
}
