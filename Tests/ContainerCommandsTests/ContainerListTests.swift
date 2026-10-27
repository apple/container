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

import ArgumentParser
import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerCommands

@Suite("ContainerList flag and filter tests")
struct ContainerListTests {

    private func makeTestSnapshot(id: String, labels: [String: String]) -> ContainerSnapshot {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        var config = ContainerConfiguration(
            id: id,
            image: image,
            process: process
        )
        config.labels = labels
        return ContainerSnapshot(
            configuration: config,
            status: .running,
            networks: [],
            startedDate: nil
        )
    }

    // MARK: - Argument Parsing Tests

    @Test func defaultArguments() throws {
        let cmd = try Application.ContainerList.parse([])
        #expect(cmd.all == false)
        #expect(cmd.filter.isEmpty)
        #expect(cmd.quiet == false)
        #expect(cmd.format == .table)
    }

    @Test func parseSingleFilterLong() throws {
        let cmd = try Application.ContainerList.parse(["--filter", "label=env=production"])
        #expect(cmd.filter == ["label=env=production"])
    }

    @Test func parseSingleFilterShort() throws {
        let cmd = try Application.ContainerList.parse(["-f", "label=env=production"])
        #expect(cmd.filter == ["label=env=production"])
    }

    @Test func parseMultipleFilters() throws {
        let cmd = try Application.ContainerList.parse([
            "-f", "label=env=production",
            "--filter", "label=tier=backend",
            "-f", "label=orchestrator",
        ])
        #expect(cmd.filter == [
            "label=env=production",
            "label=tier=backend",
            "label=orchestrator",
        ])
    }

    @Test func parseFilterWithAllFlag() throws {
        let cmd = try Application.ContainerList.parse(["-a", "-f", "label=env=stage"])
        #expect(cmd.all == true)
        #expect(cmd.filter == ["label=env=stage"])
    }

    // MARK: - Filter Syntax Parsing Tests

    @Test func parseLabelFilterPresence() throws {
        let parsed = try Application.ContainerList.parseLabelFilter("label=my-label")
        #expect(parsed == .presence(key: "my-label"))
    }

    @Test func parseLabelFilterExact() throws {
        let parsed = try Application.ContainerList.parseLabelFilter("label=env=prod")
        #expect(parsed == .exact(key: "env", value: "prod"))
    }

    @Test func parseLabelFilterExactWithEqualsInValue() throws {
        let parsed = try Application.ContainerList.parseLabelFilter("label=url=https://example.com?query=1")
        #expect(parsed == .exact(key: "url", value: "https://example.com?query=1"))
    }

    @Test func parseLabelFilterExactWithEmptyValue() throws {
        let parsed = try Application.ContainerList.parseLabelFilter("label=empty=")
        #expect(parsed == .exact(key: "empty", value: ""))
    }

    @Test func parseLabelFilterRejectsUnsupportedFilter() throws {
        #expect(throws: ValidationError.self) {
            try Application.ContainerList.parseLabelFilter("name=my-container")
        }
        #expect(throws: ValidationError.self) {
            try Application.ContainerList.parseLabelFilter("status=running")
        }
    }

    @Test func parseLabelFilterRejectsEmptyKey() throws {
        #expect(throws: ValidationError.self) {
            try Application.ContainerList.parseLabelFilter("label=")
        }
        #expect(throws: ValidationError.self) {
            try Application.ContainerList.parseLabelFilter("label==value")
        }
    }

    // MARK: - Container Matching Logic Tests

    @Test func matchesEmptyFilters() {
        let snapshot = makeTestSnapshot(id: "c1", labels: ["env": "prod"])
        #expect(Application.ContainerList.matches(container: snapshot, filters: []))
    }

    @Test func matchesLabelPresence() {
        let c1 = makeTestSnapshot(id: "c1", labels: ["managed-by": "orchestrator"])
        let c2 = makeTestSnapshot(id: "c2", labels: ["managed-by": ""])
        let c3 = makeTestSnapshot(id: "c3", labels: ["other": "val"])

        let filter = Application.ContainerList.LabelFilter.presence(key: "managed-by")
        #expect(Application.ContainerList.matches(container: c1, filters: [filter]))
        #expect(Application.ContainerList.matches(container: c2, filters: [filter]))
        #expect(!Application.ContainerList.matches(container: c3, filters: [filter]))
    }

    @Test func matchesLabelExactValue() {
        let c1 = makeTestSnapshot(id: "c1", labels: ["env": "prod"])
        let c2 = makeTestSnapshot(id: "c2", labels: ["env": "staging"])
        let c3 = makeTestSnapshot(id: "c3", labels: [:])

        let filter = Application.ContainerList.LabelFilter.exact(key: "env", value: "prod")
        #expect(Application.ContainerList.matches(container: c1, filters: [filter]))
        #expect(!Application.ContainerList.matches(container: c2, filters: [filter]))
        #expect(!Application.ContainerList.matches(container: c3, filters: [filter]))
    }

    @Test func matchesLabelExactValueWithRegexSpecialChars() {
        let c1 = makeTestSnapshot(id: "c1", labels: ["version": "1.0.0"])
        let c2 = makeTestSnapshot(id: "c2", labels: ["version": "1a0b0"])
        let c3 = makeTestSnapshot(id: "c3", labels: ["version": "1.0.0.1"])

        let filter = Application.ContainerList.LabelFilter.exact(key: "version", value: "1.0.0")
        #expect(Application.ContainerList.matches(container: c1, filters: [filter]))
        #expect(!Application.ContainerList.matches(container: c2, filters: [filter]))
        #expect(!Application.ContainerList.matches(container: c3, filters: [filter]))
    }

    @Test func matchesMultipleFiltersLogicalAnd() {
        let c1 = makeTestSnapshot(id: "c1", labels: ["env": "prod", "tier": "web", "team": "dev"])
        let c2 = makeTestSnapshot(id: "c2", labels: ["env": "prod", "tier": "db", "team": "dev"])
        let c3 = makeTestSnapshot(id: "c3", labels: ["env": "stage", "tier": "web"])

        let filters: [Application.ContainerList.LabelFilter] = [
            .exact(key: "env", value: "prod"),
            .exact(key: "tier", value: "web"),
            .presence(key: "team"),
        ]

        #expect(Application.ContainerList.matches(container: c1, filters: filters))
        #expect(!Application.ContainerList.matches(container: c2, filters: filters))
        #expect(!Application.ContainerList.matches(container: c3, filters: filters))
    }
}
