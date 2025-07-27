//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import Testing
import Logging
import ContainerizationError

@testable import ComposeCore

struct ProjectConverterTests {
    let log = Logger(label: "test")

    @Test
    func testConvertBasicProject() throws {
        let yaml = """
        version: '3'
        services:
          web:
            image: nginx:latest
            ports:
              - "8080:80"
        """

        let parser: ComposeParser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)

        let converter: ProjectConverter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "myapp"
        )

        #expect(project.name == "myapp")
        #expect(project.services.count == 1)
        #expect(project.services["web"] != nil)

        let webService = try #require(project.services["web"])
        #expect(webService.name == "web")
        #expect(webService.image == "nginx:latest")
        #expect(webService.containerName == "myapp_web")
    }

    @Test
    func testConvertServiceWithBuild() throws {
        let yaml = """
        version: '3'
        services:
          backend:
            build:
              context: .
              dockerfile: Dockerfile
              args:
                NODE_ENV: development
            ports:
              - "3000:3000"
        """

        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)

        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "testapp"
        )

        #expect(project.name == "testapp")
        #expect(project.services.count == 1)

        let backendService = try #require(project.services["backend"])
        #expect(backendService.name == "backend")
        #expect(backendService.image == nil) // No image specified
        #expect(backendService.build != nil) // Build config should be present
        #expect(backendService.hasBuild == true) // Should have build configuration

        // Test effective image name generation
        let effectiveImage = backendService.effectiveImageName(projectName: "testapp")
        #expect(effectiveImage.hasPrefix("testapp_backend:"))
    }

    @Test
    func testConvertServiceWithImageAndBuild() throws {
        let yaml = """
        version: '3'
        services:
          frontend:
            image: node:18-alpine
            build:
              context: ./frontend
              dockerfile: Dockerfile.dev
        """

        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)

        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "testapp"
        )

        let frontendService = try #require(project.services["frontend"])
        #expect(frontendService.image == "node:18-alpine")
        #expect(frontendService.build != nil)
        #expect(frontendService.hasBuild == true) // Has build+image; Compose builds and tags to image

        // Effective image should be the specified image
        let effectiveImage = frontendService.effectiveImageName(projectName: "testapp")
        #expect(effectiveImage == "node:18-alpine")
    }

    @Test
    func testPortRangeExpansion() throws {
        let yaml = """
        version: '3'
        services:
          svc:
            image: alpine
            ports:
              - "4510-4512:4510-4512/udp"
        """
        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let cf = try parser.parse(from: data)
        let proj = try ProjectConverter(log: log).convert(composeFile: cf, projectName: "p")
        let svc = try #require(proj.services["svc"])
        #expect(svc.ports.count == 3)
        #expect(svc.ports[0].portProtocol == "udp")
        #expect(svc.ports[0].hostPort == "4510")
        #expect(svc.ports[2].containerPort == "4512")
    }

    @Test
    func testContainerOnlyMountBecomesAnonymousVolume() throws {
        let yaml = """
        version: '3'
        services:
          svc:
            image: alpine
            volumes:
              - /var/tmp
        """
        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let cf = try parser.parse(from: data)
        let proj = try ProjectConverter(log: log).convert(composeFile: cf, projectName: "p")
        let svc = try #require(proj.services["svc"])
        #expect(svc.volumes.count == 1)
        #expect(svc.volumes[0].type == .volume)
        #expect(svc.volumes[0].source.isEmpty)
        #expect(svc.volumes[0].target == "/var/tmp")
    }
}
