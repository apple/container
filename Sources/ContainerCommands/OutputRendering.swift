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

    public static let compact = JSONOptions(outputFormatting: [.sortedKeys], dateEncodingStrategy: .iso8601)
    public static let pretty = JSONOptions(outputFormatting: [.prettyPrinted, .sortedKeys], dateEncodingStrategy: .iso8601)

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
/// All list commands route their output through these methods. The machine-readable
/// payload is encoded separately from table/quiet output, since the payload model
/// often differs from the display model.
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
    ///
    /// TOML has no top-level array, so array payloads are wrapped under a stable
    /// `items` key (JSON and YAML emit a top-level array instead); a non-array
    /// value encodes as a normal top-level table.
    public static func renderTOML<T: Encodable>(_ value: T) throws -> String {
        let encoder = TOMLEncoder()
        encoder.outputFormatting = .sortedKeys
        if value is [Any] {
            return try encoder.encodeToString(["items": value])
        }
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

    /// Renders `payload` in the requested format, encoding it for the
    /// machine-readable formats and delegating `.table` to the caller.
    ///
    /// This is the single place where `ListFormat` is matched exhaustively, so
    /// adopting commands handle every format by construction: a new `ListFormat`
    /// case becomes a compile error here until it is given an encoder.
    public static func render<J: Encodable>(
        payload: J, format: ListFormat, jsonOptions: JSONOptions = .compact, table: () throws -> String
    ) throws {
        switch format {
        case .json: try emit(renderJSON(payload, options: jsonOptions))
        case .yaml: try emit(renderYAML(payload))
        case .toml: try emit(renderTOML(payload))
        case .table: try emit(table())
        }
    }

    /// Renders list output in the requested format.
    ///
    /// The machine-readable payload and the display model may be the same type
    /// (e.g., `ManagedContainer`) or different types.
    public static func render<J: Encodable, D: ListDisplayable>(
        payload: J, display: [D], format: ListFormat, quiet: Bool, jsonOptions: JSONOptions = .compact
    ) throws {
        try render(payload: payload, format: format, jsonOptions: jsonOptions) {
            renderList(display, quiet: quiet)
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
