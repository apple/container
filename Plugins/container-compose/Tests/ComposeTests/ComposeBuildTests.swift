//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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

import ComposeCore
import Foundation
import Testing

@testable import ComposePlugin

struct ComposeBuildTests {
    @Test
    func testBuildPlanDefaultsToBuildableServicesOnly() throws {
        let command = ComposeBuild()
        let project = Project(
            name: "demo",
            services: [
                "api": Service(name: "api", image: "demo:api", build: BuildConfig(context: ".", dockerfile: "/tmp/Dockerfile", target: "dev")),
                "redis": Service(name: "redis", image: "redis:7-alpine"),
                "worker": Service(name: "worker", image: "demo:worker", build: BuildConfig(context: ".", dockerfile: "/tmp/Dockerfile.worker")),
            ]
        )

        let plan = try command.buildPlan(project: project, selectedServices: [])

        #expect(plan.map(\.name) == ["api", "worker"])
    }

    @Test
    func testBuildPlanRejectsServicesWithoutBuildSections() throws {
        let command = ComposeBuild()
        let project = Project(
            name: "demo",
            services: [
                "redis": Service(name: "redis", image: "redis:7-alpine"),
            ]
        )

        #expect(throws: Error.self) {
            _ = try command.buildPlan(project: project, selectedServices: ["redis"])
        }
    }

    @Test
    func testBuildPlanRejectsMissingServices() throws {
        let command = ComposeBuild()
        let project = Project(name: "demo", services: [:])

        #expect(throws: Error.self) {
            _ = try command.buildPlan(project: project, selectedServices: ["missing"])
        }
    }

    @Test
    func testConvertProjectIncludesExplicitlySelectedProfiledService() throws {
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: """
        services:
          backend:
            profiles: [worktree]
            image: demo:backend
            build:
              context: .
        """.data(using: .utf8)!)

        let command = try ComposeBuild.parse(["backend"])

        let project = try command.convertProject(
            composeFile: composeFile,
            projectName: "demo",
            projectDirectory: URL(fileURLWithPath: "/tmp")
        )

        #expect(project.services["backend"] != nil)
    }
}
