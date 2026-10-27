//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import ContainerizationExtras
import Foundation
import SwiftProtobuf

extension Application {
    public struct ContainerList: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List running containers",
            aliases: ["ls"])

        public enum LabelFilter: Equatable, Sendable {
            case presence(key: String)
            case exact(key: String, value: String)
        }

        @Flag(name: .shortAndLong, help: "Include containers that are not running")
        var all = false

        @Option(
            name: [.short, .customLong("filter")],
            help: "Filter output based on conditions provided (format: label=key or label=key=value)"
        )
        var filter: [String] = []

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .shortAndLong, help: "Only output the container ID")
        var quiet = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public static func parseLabelFilter(_ filterString: String) throws -> LabelFilter {
            let prefix = "label="
            guard filterString.hasPrefix(prefix) else {
                throw ValidationError("Invalid filter '\(filterString)': only 'label' filters ('label=key' or 'label=key=value') are supported")
            }
            let spec = String(filterString.dropFirst(prefix.count))
            guard !spec.isEmpty else {
                throw ValidationError("Invalid filter '\(filterString)': label key cannot be empty")
            }
            if let equalIndex = spec.firstIndex(of: "=") {
                let key = String(spec[..<equalIndex])
                let value = String(spec[spec.index(after: equalIndex)...])
                guard !key.isEmpty else {
                    throw ValidationError("Invalid filter '\(filterString)': label key cannot be empty")
                }
                return .exact(key: key, value: value)
            } else {
                return .presence(key: spec)
            }
        }

        public static func matches(container: ContainerSnapshot, filters: [LabelFilter]) -> Bool {
            for filter in filters {
                switch filter {
                case .presence(let key):
                    guard container.configuration.labels.keys.contains(key) else {
                        return false
                    }
                case .exact(let key, let value):
                    guard container.configuration.labels[key] == value else {
                        return false
                    }
                }
            }
            return true
        }

        public func run() async throws {
            let client = ContainerClient()

            let parsedFilters = try self.filter.map { try Self.parseLabelFilter($0) }

            var serverLabels: [String: String] = [:]
            for filter in parsedFilters {
                switch filter {
                case .exact(let key, let value):
                    serverLabels[key] = "^\(NSRegularExpression.escapedPattern(for: value))$"
                case .presence:
                    break
                }
            }

            let filters = ContainerListFilters(
                status: self.all ? nil : .running,
                labels: serverLabels
            ).withoutMachines()

            let containers = try await client.list(filters: filters)
            let matchingContainers = containers.filter { Self.matches(container: $0, filters: parsedFilters) }
            let items = matchingContainers.map { ManagedContainer($0) }
            try Output.render(payload: items, display: items, format: format, quiet: quiet)
        }
    }
}
