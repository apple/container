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

import ContainerCommands
import ContainerResource
import Testing

// MARK: - ManagedContainer conformance tests

struct ManagedContainerDisplayTests {
    /// Builds a minimal `ManagedContainer` for table rendering tests.
    private func makeManagedContainer(startedDate: Date? = nil) -> ManagedContainer {
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
        let configuration = ContainerConfiguration(id: "tz-test", image: image, process: process)
        let status = ContainerStatus(state: .running, networks: [], startedDate: startedDate)
        return ManagedContainer(configuration: configuration, status: status)
    }

    @Test
    func tableHeaderHasNineColumns() {
        #expect(ManagedContainer.tableHeader.count == 9)
        #expect(ManagedContainer.tableHeader[0] == "ID")
        #expect(ManagedContainer.tableHeader[4] == "STATE")
        #expect(ManagedContainer.tableHeader[8] == "STARTED")
    }

    @Test
    func startedColumnIsEmptyWhenContainerNeverStarted() {
        let row = makeManagedContainer(startedDate: nil).tableRow
        #expect(row.count == ManagedContainer.tableHeader.count)
        #expect(row[8] == "")
    }

    /// Regression test for https://github.com/apple/container/issues/1684:
    /// the STARTED column must show wall-clock time in the user's local
    /// timezone, not UTC.
    @Test
    func startedColumnShowsLocalTimeComponents() {
        // Fixed instant: 2026-06-12 16:18:46 UTC.
        let started = Date(timeIntervalSince1970: 1_781_540_326)
        let rendered = makeManagedContainer(startedDate: started).tableRow[8]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let local = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: started)
        let expectedPrefix = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            local.year!, local.month!, local.day!, local.hour!, local.minute!, local.second!
        )
        #expect(rendered.hasPrefix(expectedPrefix), "expected local wall-clock prefix \(expectedPrefix), got \(rendered)")
    }

    @Test
    func startedColumnRoundTripsToSameInstant() throws {
        let started = Date(timeIntervalSince1970: 1_781_540_326)
        let rendered = makeManagedContainer(startedDate: started).tableRow[8]

        // Parse with an independent implementation to prove the rendered
        // string is valid ISO 8601 denoting the same instant.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let parsed = try #require(formatter.date(from: rendered), "STARTED value must be valid ISO 8601: \(rendered)")
        #expect(abs(parsed.timeIntervalSince(started)) < 1, "rendered STARTED value must denote the same instant")
    }

    @Test
    func startedColumnCarriesLocalUTCOffsetDesignator() {
        let started = Date(timeIntervalSince1970: 1_781_540_326)
        let rendered = makeManagedContainer(startedDate: started).tableRow[8]

        let offsetSeconds = TimeZone.current.secondsFromGMT(for: started)
        if offsetSeconds == 0 {
            // UTC hosts legitimately render "Z" or a zero offset.
            #expect(
                rendered.hasSuffix("Z") || rendered.hasSuffix("+00:00") || rendered.hasSuffix("+0000"),
                "expected UTC designator, got \(rendered)")
        } else {
            // Non-UTC hosts must not render the UTC designator (the pre-fix behavior).
            #expect(!rendered.hasSuffix("Z"), "STARTED must not be rendered in UTC on non-UTC hosts: \(rendered)")
            let sign = offsetSeconds < 0 ? "-" : "+"
            let absOffset = abs(offsetSeconds)
            let (hours, minutes) = (absOffset / 3600, (absOffset % 3600) / 60)
            // Foundation renders the offset with or without a colon depending on version.
            let expectedOffsets = [
                String(format: "%@%02d:%02d", sign, hours, minutes),
                String(format: "%@%02d%02d", sign, hours, minutes),
            ]
            #expect(
                expectedOffsets.contains { rendered.hasSuffix($0) },
                "expected UTC offset suffix in \(expectedOffsets), got \(rendered)")
        }
    }
}

// MARK: - NetworkResource ListDisplayable conformance tests

struct NetworkResourceDisplayTests {
    @Test
    func tableHeaderHasTwoColumns() {
        #expect(NetworkResource.tableHeader.count == 2)
        #expect(NetworkResource.tableHeader == ["NETWORK", "SUBNET"])
    }
}
