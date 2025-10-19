//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import ContainerPlugin
import Foundation
import Testing

struct MockPluginError: Error {}

struct MockPluginFactory: PluginFactory {
    public static let throwSuffix = "throw"

    private let plugins: [URL: Plugin]

    private let throwingURL: URL

    public init(tempURL: URL, plugins: [String: Plugin?]) throws {
        let fm = FileManager.default
        var prefixedPlugins: [URL: Plugin] = [:]
        for (suffix, plugin) in plugins {
            let url = tempURL.appending(path: suffix)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            prefixedPlugins[url.standardizedFileURL] = plugin
        }
        self.plugins = prefixedPlugins
        self.throwingURL = tempURL.appending(path: Self.throwSuffix).standardizedFileURL
    }

    public func create(installURL: URL) throws -> Plugin? {
        let url = installURL.standardizedFileURL
        guard url != self.throwingURL else {
            throw MockPluginError()
        }
        return plugins[url]
    }

    public func create(parentURL: URL, name: String) throws -> Plugin? {
        let url = parentURL.appendingPathComponent(name).standardizedFileURL
        guard url != self.throwingURL else {
            throw MockPluginError()
        }
        return plugins[url]
    }

}
