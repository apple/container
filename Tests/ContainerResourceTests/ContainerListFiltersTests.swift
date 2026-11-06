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

import Testing

@testable import ContainerResource

struct ContainerListFiltersTests {
    private let hidden = [ResourcePluginValues.machine, ResourcePluginValues.cluster]

    @Test func testWithoutPluginsBuildsExclusionPattern() {
        let filters = ContainerListFilters().withoutPlugins(hidden)
        #expect(filters.labels[ResourceLabelKeys.plugin] == "^(?!(?:machine|cluster)$)")
    }

    @Test func testWithoutPluginsEscapesNames() {
        let filters = ContainerListFilters().withoutPlugins(["a.b"])
        #expect(filters.labels[ResourceLabelKeys.plugin] == #"^(?!(?:a\.b)$)"#)
    }

    @Test func testWithoutPluginsKeepsOtherFilters() {
        let filters = ContainerListFilters(ids: ["a"], status: .stopped).withoutPlugins(hidden)
        #expect(filters.ids == ["a"])
        #expect(filters.status == .stopped)
    }

    @Test func testWithoutPluginsWithNoNamesIsUnchanged() {
        #expect(ContainerListFilters().withoutPlugins([]).labels.isEmpty)
    }

    @Test func testWithPluginBuildsExactMatchPattern() {
        let filters = ContainerListFilters().withPlugin(ResourcePluginValues.cluster)
        #expect(filters.labels[ResourceLabelKeys.plugin] == "^cluster$")
    }

    @Test func testWithPluginEscapesName() {
        let filters = ContainerListFilters().withPlugin("a.b")
        #expect(filters.labels[ResourceLabelKeys.plugin] == #"^a\.b$"#)
    }

    @Test func testWithPluginKeepsOtherFilters() {
        let filters = ContainerListFilters(ids: ["a"], status: .running).withPlugin(ResourcePluginValues.cluster)
        #expect(filters.ids == ["a"])
        #expect(filters.status == .running)
    }
}
