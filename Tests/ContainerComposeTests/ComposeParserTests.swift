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
import ContainerizationError
import Logging
import Yams

@testable import ContainerCompose

struct ComposeParserTests {
    let log = Logger(label: "test")
    
    @Test
    func testParseBasicComposeFile() throws {
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
        
        #expect(composeFile.version == "3")
        #expect(composeFile.services.count == 1)
        #expect(composeFile.services["web"]?.image == "nginx:latest")
        #expect(composeFile.services["web"]?.ports?.count == 1)
        #expect(composeFile.services["web"]?.ports?[0] == "8080:80")
    }
    
    @Test
    func testParseWithDefaultValues() throws {
        let yaml = """
        version: '3'
        services:
          app:
            image: ${IMAGE_NAME:-ubuntu:latest}
            environment:
              DB_PORT: ${DB_PORT:-5432}
        """
        
        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)
        
        // Should use default values when env vars not set
        #expect(composeFile.services["app"]?.image == "ubuntu:latest")
        
        // Check environment
        if case .dict(let env) = composeFile.services["app"]?.environment {
            #expect(env["DB_PORT"] == "5432")
        } else {
            Issue.record("Expected environment to be a dictionary")
        }
    }
    
    @Test
    func testParsePortFormats() throws {
        let yaml = """
        version: '3'
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
              - "127.0.0.1:9000:9000"
              - "3000:3000"
        """
        
        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)
        
        let ports = composeFile.services["web"]?.ports ?? []
        #expect(ports.count == 3)
        #expect(ports[0] == "8080:80")
        #expect(ports[1] == "127.0.0.1:9000:9000")
        #expect(ports[2] == "3000:3000")
    }
    
    @Test
    func testParseDependencies() throws {
        let yaml = """
        version: '3'
        services:
          db:
            image: postgres
          web:
            image: nginx
            depends_on:
              - db
          worker:
            image: worker
            depends_on:
              - db
              - web
        """
        
        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)
        
        // The parser converts the YAML structure
        #expect(composeFile.services["db"]?.dependsOn == nil)
        #expect(composeFile.services["web"]?.dependsOn != nil)
        #expect(composeFile.services["worker"]?.dependsOn != nil)
    }
    
    @Test
    func testParseVolumes() throws {
        let yaml = """
        version: '3'
        services:
          app:
            image: ubuntu
            volumes:
              - /host/path:/container/path
              - /host/path2:/container/path2:ro
        """
        
        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)
        
        let volumes = composeFile.services["app"]?.volumes ?? []
        #expect(volumes.count == 2)
        #expect(volumes[0] == "/host/path:/container/path")
        #expect(volumes[1] == "/host/path2:/container/path2:ro")
    }
    
    @Test
    func testParseInvalidYAML() throws {
        let yaml = """
        this is not valid yaml: [
        """
        
        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        
        #expect {
            _ = try parser.parse(from: data)
        } throws: { error in
            // Can be either ContainerizationError or YamlError
            return true
        }
    }
    
    @Test
    func testParseWithProfiles() throws {
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
        
        #expect(composeFile.services["web"]?.profiles == ["frontend"])
        #expect(composeFile.services["api"]?.profiles == ["backend", "api"])
        #expect(composeFile.services["db"]?.profiles == nil)
    }
}