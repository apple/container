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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerCommands

struct ComposeSupportTests {
    @Test
    func discoversPreferredComposeFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let preferred = directory.appendingPathComponent("compose.yaml")
        let fallback = directory.appendingPathComponent("docker-compose.yml")
        try "services: {}\n".write(to: preferred, atomically: true, encoding: .utf8)
        try "services: {}\n".write(to: fallback, atomically: true, encoding: .utf8)

        let discovered = try ComposeSupport.discoveredComposeFile(in: directory)
        #expect(discovered.lastPathComponent == "compose.yaml")
    }

    @Test
    func interpolatesVariablesAndDefaults() throws {
        let result = try ComposeSupport.interpolate(
            """
            services:
              web:
                image: ${IMAGE_NAME:-nginx}:latest
                environment:
                  FOO: $BAR
                  LIT: $$VALUE
            """,
            environment: [
                "BAR": "baz",
            ]
        )

        #expect(result.contains("image: nginx:latest"))
        #expect(result.contains("FOO: baz"))
        #expect(result.contains("LIT: $VALUE"))
    }

    @Test
    func rejectsUnsupportedServiceKeys() throws {
        #expect {
            try ComposeSupport.validateRawComposeYaml(
                """
                services:
                  web:
                    image: nginx
                    deploy:
                      replicas: 2
                """
            )
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("unsupported Compose keys")
        }
    }

    @Test
    func normalizesProjectResourcesAndServiceOrder() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let composeURL = directory.appendingPathComponent("compose.yaml")
        try """
        name: sample
        services:
          db:
            image: postgres:16
            volumes:
              - data:/var/lib/postgresql/data
          web:
            image: nginx:latest
            depends_on:
              - db
            networks:
              - front
            volumes:
              - ./site:/usr/share/nginx/html:ro
        volumes:
          data: {}
        networks:
          front: {}
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let project = try ComposeSupport.loadProject(
            filePath: composeURL.path(percentEncoded: false),
            projectName: nil,
            profiles: [],
            envFiles: []
        )

        #expect(project.name == "sample")
        #expect(project.networks == ["sample_default", "sample_front"])
        #expect(project.volumes == ["sample_data"])
        let orderedNames = try project.orderedServices.map(\.name)
        #expect(orderedNames == ["db", "web"])
        #expect(project.services["db"]?.volumes == ["sample_data:/var/lib/postgresql/data"])
        #expect(project.services["db"]?.networks == ["sample_default"])
        #expect(project.services["web"]?.networks == ["sample_front"])
    }

    @Test
    func filtersServicesByProfile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let composeURL = directory.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: nginx:latest
          admin:
            image: nginx:latest
            profiles:
              - ops
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let project = try ComposeSupport.loadProject(
            filePath: composeURL.path(percentEncoded: false),
            projectName: "demo",
            profiles: [],
            envFiles: []
        )
        #expect(project.services.keys.sorted() == ["admin", "web"])

        let profiled = try ComposeSupport.loadProject(
            filePath: composeURL.path(percentEncoded: false),
            projectName: "demo",
            profiles: ["web"],
            envFiles: []
        )
        #expect(profiled.services.keys.sorted() == ["web"])
    }

    @Test
    func acceptsHealthcheckAndDependencyCondition() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let composeURL = directory.appendingPathComponent("compose.yaml")
        try """
        services:
          db:
            image: postgres:16
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U postgres"]
              interval: 5s
              timeout: 5s
              retries: 5
          api:
            image: nginx:latest
            depends_on:
              db:
                condition: service_healthy
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let project = try ComposeSupport.loadProject(
            filePath: composeURL.path(percentEncoded: false),
            projectName: "demo",
            profiles: [],
            envFiles: []
        )

        let db = try #require(project.services["db"])
        let api = try #require(project.services["api"])
        #expect(db.healthcheck != nil)
        #expect(api.dependencyConditions == [
            NormalizedComposeDependency(service: "db", condition: .serviceHealthy)
        ])
    }

    @Test
    func tokenizesStringCommandAndEntrypointWithoutImplicitShellWrapping() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let composeURL = directory.appendingPathComponent("compose.yaml")
        try """
        services:
          minio:
            image: minio/minio:latest
            command: server /data --console-address ":9001"
          setup:
            image: minio/mc:latest
            entrypoint: /bin/sh -c "echo hello world"
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let project = try ComposeSupport.loadProject(
            filePath: composeURL.path(percentEncoded: false),
            projectName: "demo",
            profiles: [],
            envFiles: []
        )

        let minio = try #require(project.services["minio"])
        let setup = try #require(project.services["setup"])
        #expect(minio.entrypoint == nil)
        #expect(minio.commandArguments == ["server", "/data", "--console-address", ":9001"])
        #expect(setup.entrypoint == "/bin/sh")
        #expect(setup.commandArguments == ["-c", "echo hello world"])
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
