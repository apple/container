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

@testable import ContainerCompose

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
        
        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)
        
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "myapp"
        )
        
        #expect(project.name == "myapp")
        #expect(project.services.count == 1)
        #expect(project.services["web"] != nil)
        
        let webService = project.services["web"]!
        #expect(webService.name == "web")
        #expect(webService.image == "nginx:latest")
        #expect(webService.containerName == "myapp_web")
    }
    
    @Test
    func testConvertWithProfiles() throws {
        let yaml = """
        version: '3.9'
        services:
          web:
            image: nginx
            profiles: ["frontend"]
          api:
            image: api:latest
            profiles: ["backend", "api"]
          db:
            image: postgres
        """
        
        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)
        let converter = ProjectConverter(log: log)
        
        // No profiles - only services without profiles
        let project1 = try converter.convert(
            composeFile: composeFile,
            projectName: "myapp",
            profiles: []
        )
        #expect(project1.services.count == 1)
        #expect(project1.services.keys.contains("db"))
        
        // Frontend profile
        let project2 = try converter.convert(
            composeFile: composeFile,
            projectName: "myapp",
            profiles: ["frontend"]
        )
        #expect(project2.services.count == 2)
        #expect(project2.services.keys.contains("db"))
        #expect(project2.services.keys.contains("web"))
        
        // Backend profile
        let project3 = try converter.convert(
            composeFile: composeFile,
            projectName: "myapp",
            profiles: ["backend"]
        )
        #expect(project3.services.count == 2)
        #expect(project3.services.keys.contains("db"))
        #expect(project3.services.keys.contains("api"))
    }
    
    @Test
    func testConvertEnvironment() throws {
        let yaml = """
        version: '3'
        services:
          app:
            image: ubuntu
            environment:
              KEY1: value1
              KEY2: value2
        """
        
        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)
        
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "myapp"
        )
        
        let env = project.services["app"]?.environment ?? [:]
        #expect(env["KEY1"] == "value1")
        #expect(env["KEY2"] == "value2")
    }
    
    @Test
    func testConvertVolumes() throws {
        let yaml = """
        version: '3'
        services:
          app:
            image: ubuntu
            volumes:
              - /host/path:/container/path
              - /host/path2:/container/path2:ro
              - /data:/tmp
        """
        
        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)
        
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "myapp"
        )
        
        let volumes = project.services["app"]?.volumes ?? []
        #expect(volumes.count == 3)
        
        // Check first volume
        let vol1 = volumes[0]
        #expect(vol1.source == "/host/path")
        #expect(vol1.target == "/container/path")
        
        // Check second volume
        let vol2 = volumes[1]
        #expect(vol2.source == "/host/path2")
        #expect(vol2.target == "/container/path2")
        #expect(vol2.readOnly == true)
        
        // Check third volume
        let vol3 = volumes[2]
        #expect(vol3.source == "/data")
        #expect(vol3.target == "/tmp")
    }
    
    @Test
    func testConvertPorts() throws {
        let yaml = """
        version: '3'
        services:
          web:
            image: nginx
            ports:
              - "127.0.0.1:8080:80/tcp"
              - "8443:443"
        """
        
        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)
        
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "myapp"
        )
        
        let ports = project.services["web"]?.ports ?? []
        #expect(ports.count == 2)
        
        let port1 = ports[0]
        #expect(port1.hostIP == "127.0.0.1")
        #expect(port1.hostPort == "8080")
        #expect(port1.containerPort == "80")
        #expect(port1.portProtocol == "tcp")
        
        let port2 = ports[1]
        #expect(port2.hostIP == nil)
        #expect(port2.hostPort == "8443")
        #expect(port2.containerPort == "443")
    }
}