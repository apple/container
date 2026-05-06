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

import Foundation
import TOML
import Yams

/// Options for JSON rendering, wrapping the knobs on `JSONEncoder`.
public struct JSONOptions: Sendable {
    public var outputFormatting: JSONEncoder.OutputFormatting = []
    public var dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .deferredToDate

    public static let compact = JSONOptions()
    public static let prettySorted = JSONOptions(outputFormatting: [.prettyPrinted, .sortedKeys])

    public init(
        outputFormatting: JSONEncoder.OutputFormatting = [],
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .deferredToDate
    ) {
        self.outputFormatting = outputFormatting
        self.dateEncodingStrategy = dateEncodingStrategy
    }
}

/// Shared rendering helpers for CLI output.
///
/// All list commands route their output through these methods. JSON rendering
/// is separate from table/quiet rendering because the JSON model often differs
/// from the display model (e.g., `Volume` for JSON vs `PrintableVolume` for table).
public enum Output {
    /// Renders an `Encodable` value as a JSON string.
    public static func renderJSON<T: Encodable>(_ value: T, options: JSONOptions = .compact) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = options.outputFormatting
        encoder.dateEncodingStrategy = options.dateEncodingStrategy
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    public static func renderYAML<T: Encodable>(_ value: T) throws -> String {
        let encoder = YAMLEncoder()
        let data = try encoder.encode(value)
        return data
    }

    /// Renders an `Encodable` value as a TOML string.
    public static func renderTOML<T: Encodable>(_ value: T) throws -> String {
        let encoder = TOMLEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encodeToString(value)
    }

    /// Renders a list of displayable items as a table (with header) or quiet-mode identifiers.
    public static func renderList<T: ListDisplayable>(_ items: [T], quiet: Bool) -> String {
        if quiet {
            return items.map(\.quietValue).joined(separator: "\n")
        }
        return renderTable(items)
    }

    /// Renders a list of displayable items as a column-aligned table with a header row.
    public static func renderTable<T: ListDisplayable>(_ items: [T]) -> String {
        var rows: [[String]] = [T.tableHeader]
        for item in items {
            rows.append(item.tableRow)
        }
        return TableOutput(rows: rows).format()
    }

    /// Renders list output in the requested format.
    ///
    /// The JSON and display models may be the same type (e.g., `PrintableContainer`)
    /// or different types (e.g., `Volume` for JSON and `PrintableVolume` for table).
    public static func render<J: Encodable, D: ListDisplayable>(
        json: J, display: [D], format: ListFormat, quiet: Bool
    ) throws {
        switch format {
        case .json: try emit(renderJSON(json))
        case .yaml: try emit(renderYAML(json))
        case .table: emit(renderList(display, quiet: quiet))
        case .toml: try emit(renderTOML(json))
        }
    }

    /// Writes rendered output to stdout. No-ops on empty strings to avoid blank lines
    /// (e.g., `container list -q` with zero results should produce no output, not a newline).
    public static func emit(_ output: String) {
        if !output.isEmpty {
            print(output)
        }
    }
}
