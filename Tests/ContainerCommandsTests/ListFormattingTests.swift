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
    func prettySortedIsMultiLine() throws {
        let items = [TestItem(id: "a", name: "b")]
        let json = try Output.renderJSON(items, options: .prettySorted)
        #expect(json.contains("\n"))
    }

    @Test
    func prettySortedHasSortedKeys() throws {
        let json = try Output.renderJSON(["z": 1, "a": 2], options: .prettySorted)
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

// MARK: - JSONOptions tests

struct JSONOptionsTests {
    @Test
    func compactPresetHasNoFormatting() {
        let opts = JSONOptions.compact
        #expect(opts.outputFormatting == [])
    }

    @Test
    func prettySortedPresetHasBothFlags() {
        let opts = JSONOptions.prettySorted
        #expect(opts.outputFormatting.contains(.prettyPrinted))
        #expect(opts.outputFormatting.contains(.sortedKeys))
    }
}

// MARK: - PrintableContainer conformance tests

struct PrintableContainerDisplayTests {
    @Test
    func tableHeaderHasNineColumns() {
        #expect(PrintableContainer.tableHeader.count == 9)
        #expect(PrintableContainer.tableHeader[0] == "ID")
        #expect(PrintableContainer.tableHeader[4] == "STATE")
        #expect(PrintableContainer.tableHeader[8] == "STARTED")
    }
}

// MARK: - PrintableNetwork conformance tests

struct PrintableNetworkDisplayTests {
    @Test
    func tableHeaderHasThreeColumns() {
        #expect(PrintableNetwork.tableHeader.count == 3)
        #expect(PrintableNetwork.tableHeader == ["NETWORK", "STATE", "SUBNET"])
    }
}

// MARK: - ListFormat tests

struct ListFormatTests {
    @Test
    func hasJsonAndTableCases() {
        #expect(ListFormat.allCases.count == 2)
        #expect(ListFormat.json.rawValue == "json")
        #expect(ListFormat.table.rawValue == "table")
    }
}

// MARK: - String.elided tests

struct StringElidedTests {
    @Test
    func shortStringUnchanged() {
        #expect("hello".elided(to: 10) == "hello")
        #expect("hello".elided(to: 5) == "hello")
    }

    @Test
    func longStringTruncatedWithEllipsis() {
        #expect("hello world".elided(to: 8) == "hello...")
    }

    @Test
    func maxCountShorterThanEllipsis() {
        #expect("hello".elided(to: 2) == "..")
        #expect("hello".elided(to: 1) == ".")
        #expect("hello".elided(to: 0) == "")
    }
}
