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

import ContainerTestSupport
import Foundation
import Testing

/// Tests for `container system status` output formats and content validation.
@Suite
struct TestCLIStatus {
    struct StatusJSON: Codable {
        struct Server: Codable {
            let version: String
            let build: String
            let commit: String
            let appName: String
        }

        struct Paths: Codable {
            let appRoot: String
            let installRoot: String
            let logRoot: String?
        }

        let status: String
        // Daemon-sourced fields are only present when the apiserver is running,
        // so they are optional to allow decoding the "not running" payload too.
        let server: Server?
        let paths: Paths?
    }

    @Test func defaultDisplaysTable() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "status"])
            guard result.status == 0 else { return }

            #expect(!result.output.isEmpty)

            let lines = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
            #expect(lines.count >= 2)
            #expect(lines[0].contains("FIELD") && lines[0].contains("VALUE"))

            let fullOutput = lines.joined(separator: "\n")
            #expect(fullOutput.contains("status"))
            #expect(fullOutput.contains("running"))
            #expect(fullOutput.contains("paths.appRoot"))
            #expect(fullOutput.contains("paths.installRoot"))
            #expect(fullOutput.contains("server.version"))
            #expect(fullOutput.contains("server.commit"))
        }
    }

    @Test func jsonFormat() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "status", "--format", "json"])

            if result.status != 0 {
                #expect(!result.output.isEmpty)
                let decoded = try JSONDecoder().decode(StatusJSON.self, from: result.outputData)
                #expect(decoded.status == "not running" || decoded.status == "unregistered")
                return
            }

            #expect(!result.output.isEmpty)
            let decoded = try JSONDecoder().decode(StatusJSON.self, from: result.outputData)
            #expect(decoded.status == "running")
            #expect(!(decoded.paths?.appRoot.isEmpty ?? true))
            #expect(!(decoded.paths?.installRoot.isEmpty ?? true))
            #expect(!(decoded.server?.version.isEmpty ?? true))
            #expect(!(decoded.server?.commit.isEmpty ?? true))
            #expect(!(decoded.server?.build.isEmpty ?? true))
            #expect(!(decoded.server?.appName.isEmpty ?? true))
        }
    }

    @Test func explicitTableFormat() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "status", "--format", "table"])
            guard result.status == 0 else { return }

            #expect(!result.output.isEmpty)

            let lines = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
            #expect(lines.count >= 2)
            #expect(lines[0].contains("FIELD") && lines[0].contains("VALUE"))
            #expect(lines.joined(separator: "\n").contains("running"))
        }
    }

    @Test func statusFieldsMatch() async throws {
        try await ContainerFixture.with { f in
            let jsonResult = try f.run(["system", "status", "--format", "json"])
            let tableResult = try f.run(["system", "status", "--format", "table"])
            #expect(jsonResult.status == tableResult.status)

            guard jsonResult.status == 0 else { return }

            let decoded = try JSONDecoder().decode(StatusJSON.self, from: jsonResult.outputData)
            #expect(tableResult.output.contains(decoded.status))
            if let paths = decoded.paths {
                #expect(tableResult.output.contains(paths.appRoot))
                #expect(tableResult.output.contains(paths.installRoot))
            }
            if let server = decoded.server {
                #expect(tableResult.output.contains(server.version))
                #expect(tableResult.output.contains(server.commit))
                #expect(tableResult.output.contains(server.build))
                #expect(tableResult.output.contains(server.appName))
            }
        }
    }

    @Test func jsonOutputValidStructure() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "status", "--format", "json"])
            let decoded = try JSONDecoder().decode(StatusJSON.self, from: result.outputData)
            if result.status == 0 {
                #expect(decoded.status == "running")
                #expect(!(decoded.paths?.appRoot.isEmpty ?? true))
                #expect(!(decoded.paths?.installRoot.isEmpty ?? true))
                #expect(!(decoded.server?.version.isEmpty ?? true))
            } else {
                #expect(decoded.status == "not running" || decoded.status == "unregistered")
            }
        }
    }

    @Test func prefixOption() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "status", "--prefix", "com.apple.container."])
            guard result.status == 0 else { return }

            #expect(!result.output.isEmpty)
            let lines = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
            #expect(lines.count >= 2)
        }
    }
}
