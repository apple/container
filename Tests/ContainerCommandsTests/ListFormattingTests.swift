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
import Foundation
import Testing

@testable import ContainerCommands

// MARK: - Test ListDisplayable conformer

private struct TestItem: ListDisplayable, Codable {
    let id: String
    let name: String

    static var tableHeader: [String] { ["ID", "NAME"] }
    var tableRow: [String] { [id, name] }
    var quietValue: String { id }
}

// MARK: - TableOutput tests

struct TableOutputTests {
    @Test
    func emptyRowsProducesEmptyString() {
        #expect(TableOutput(rows: []).format() == "")
    }

    @Test
    func headerOnlyRow() {
        #expect(TableOutput(rows: [["ID", "NAME"]]).format() == "ID  NAME")
    }

    @Test
    func columnsPaddedToMaxWidth() {
        let output = TableOutput(rows: [
            ["ID", "NAME"],
            ["1", "short"],
            ["2", "a longer name"],
        ]).format()
        let lines = output.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("ID  "))
        #expect(lines[1].hasPrefix("1   "))
        #expect(lines[2].hasPrefix("2   "))
    }

    @Test
    func customSpacing() {
        let output = TableOutput(rows: [["A", "B"], ["1", "2"]], spacing: 4).format()
        #expect(output.contains("A    B"))
    }

    @Test
    func lastColumnNotPadded() {
        let lines = TableOutput(rows: [["A", "B"], ["1", "2"]]).format().split(separator: "\n")
        for line in lines {
            #expect(!line.hasSuffix(" "))
        }
    }

    @Test
    func singleColumnNoPadding() {
        let output = TableOutput(rows: [["DOMAIN"], ["example.com"], ["test.local"]]).format()
        #expect(output == "DOMAIN\nexample.com\ntest.local")
    }

    @Test
    func outputLineCountMatchesInputRowCount() {
        let rows = [["H1", "H2"], ["a", "b"], ["c", "d"], ["e", "f"]]
        let lines = TableOutput(rows: rows).format().split(separator: "\n")
        #expect(lines.count == rows.count)
    }
}

// MARK: - renderTable tests

struct RenderTableTests {
    @Test
    func rendersHeaderAndRows() {
        let items = [TestItem(id: "abc", name: "first"), TestItem(id: "def", name: "second")]
        let output = Output.renderTable(items)
        #expect(output.contains("ID"))
        #expect(output.contains("NAME"))
        #expect(output.contains("abc"))
        #expect(output.contains("second"))
    }

    @Test
    func emptyListRendersHeaderOnly() {
        let output = Output.renderTable([TestItem]())
        #expect(output.contains("ID"))
        #expect(output.contains("NAME"))
        #expect(!output.contains("\n"))
    }

    @Test
    func columnCountMatchesHeader() {
        let items = [TestItem(id: "1", name: "test")]
        let lines = Output.renderTable(items).split(separator: "\n")
        let headerColumnCount = lines[0].split(separator: " ", omittingEmptySubsequences: true).count
        let rowColumnCount = lines[1].split(separator: " ", omittingEmptySubsequences: true).count
        #expect(headerColumnCount == rowColumnCount)
    }
}

// MARK: - renderList tests

struct RenderListTests {
    @Test
    func tableMode() {
        let items = [TestItem(id: "abc", name: "first")]
        let output = Output.renderList(items, quiet: false)
        #expect(output.contains("ID"))
        #expect(output.contains("abc"))
        #expect(output.contains("first"))
    }

    @Test
    func quietMode() {
        let items = [TestItem(id: "abc", name: "first"), TestItem(id: "def", name: "second")]
        let output = Output.renderList(items, quiet: true)
        #expect(output == "abc\ndef")
    }

    @Test
    func quietModeEmptyList() {
        let output = Output.renderList([TestItem](), quiet: true)
        #expect(output == "")
    }
}

// MARK: - renderJSON tests

struct RenderJSONTests {
    @Test
    func compactProducesValidJSON() throws {
        let items = [TestItem(id: "a", name: "b")]
        let json = try Output.renderJSON(items)
        let decoded = try JSONDecoder().decode([TestItem].self, from: json.data(using: .utf8)!)
        #expect(decoded.count == 1)
        #expect(decoded[0].id == "a")
        #expect(decoded[0].name == "b")
    }

    @Test
    func compactIsSingleLine() throws {
        let items = [TestItem(id: "a", name: "b"), TestItem(id: "c", name: "d")]
        let json = try Output.renderJSON(items)
        #expect(!json.contains("\n"))
    }

    @Test
    func prettyIsMultiLine() throws {
        let items = [TestItem(id: "a", name: "b")]
        let json = try Output.renderJSON(items, options: .pretty)
        #expect(json.contains("\n"))
    }

    @Test
    func prettyHasSortedKeys() throws {
        let json = try Output.renderJSON(["z": 1, "a": 2], options: .pretty)
        let aIndex = json.range(of: "\"a\"")!.lowerBound
        let zIndex = json.range(of: "\"z\"")!.lowerBound
        #expect(aIndex < zIndex)
    }

    @Test
    func customDateStrategy() throws {
        struct Dated: Codable { let date: Date }
        let item = Dated(date: Date(timeIntervalSince1970: 0))
        let options = JSONOptions(
            outputFormatting: [.prettyPrinted, .sortedKeys],
            dateEncodingStrategy: .iso8601
        )
        let json = try Output.renderJSON(item, options: options)
        #expect(json.contains("1970-01-01"))
    }

    @Test
    func arrayEncodingMatchesOldJoinApproach() throws {
        // Verify renderJSON(array) is structurally identical to the old
        // jsonArray() approach (encode each element, join with commas).
        let items = [TestItem(id: "x", name: "y"), TestItem(id: "a", name: "b")]
        let wholeArray = try Output.renderJSON(items)
        let perElement = try items.map { try Output.renderJSON($0) }
        let joined = "[\(perElement.joined(separator: ","))]"

        let decoded1 = try JSONDecoder().decode([TestItem].self, from: wholeArray.data(using: .utf8)!)
        let decoded2 = try JSONDecoder().decode([TestItem].self, from: joined.data(using: .utf8)!)
        #expect(decoded1.count == decoded2.count)
        #expect(decoded1[0].id == decoded2[0].id)
        #expect(decoded1[1].id == decoded2[1].id)
    }
}

// MARK: - renderTOML tests

struct RenderTOMLTests {
    @Test
    func topLevelArrayProducesNonEmptyTOML() throws {
        let items = [TestItem(id: "a", name: "first"), TestItem(id: "c", name: "second")]
        let toml = try Output.renderTOML(items)
        #expect(!toml.isEmpty)
        #expect(toml.contains("first"))
        #expect(toml.contains("second"))
    }

    @Test
    func emptyArrayProducesNonEmptyTOML() throws {
        let toml = try Output.renderTOML([TestItem]())
        #expect(!toml.isEmpty)
    }

    @Test
    func singleValueEncodesAsTopLevelTable() throws {
        let toml = try Output.renderTOML(TestItem(id: "x", name: "y"))
        #expect(toml.contains("id"))
        #expect(toml.contains("x"))
    }
}

// MARK: - JSONOptions tests

struct JSONOptionsTests {
    @Test
    func compactPresetHasSortedKeys() {
        let opts = JSONOptions.compact
        #expect(opts.outputFormatting == [.sortedKeys])
        #expect(!opts.outputFormatting.contains(.prettyPrinted))
    }

    @Test
    func prettyPresetHasBothFlags() {
        let opts = JSONOptions.pretty
        #expect(opts.outputFormatting.contains(.prettyPrinted))
        #expect(opts.outputFormatting.contains(.sortedKeys))
    }
}

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

// MARK: - ListFormat tests

struct ListFormatTests {
    @Test
    func hasAllOutputFormatCases() {
        #expect(ListFormat.allCases.count == 4)
        #expect(ListFormat.json.rawValue == "json")
        #expect(ListFormat.table.rawValue == "table")
        #expect(ListFormat.yaml.rawValue == "yaml")
        #expect(ListFormat.toml.rawValue == "toml")
    }
}
