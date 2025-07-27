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

@testable import ComposeCore

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
        if case .string(let v0) = volumes[0] { #expect(v0 == "/host/path:/container/path") } else { #expect(false) }
        if case .string(let v1) = volumes[1] { #expect(v1 == "/host/path2:/container/path2:ro") } else { #expect(false) }
    }

    @Test
    func testParseLongFormVolumeAndPortRange() throws {
        let yaml = """
        version: '3.9'
        services:
          app:
            image: alpine
            volumes:
              - type: bind
                source: ~/data
                target: /data
                read_only: true
              - type: tmpfs
                target: /cache
            ports:
              - "4510-4512:4510-4512/udp"
        """

        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)
        #expect(composeFile.services["app"]?.volumes?.count == 2)
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
    
    @Test
    func testParseMultipleFiles() throws {
        // Create temporary directory for test files
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Base compose file
        let baseYaml = """
        version: '3.8'
        services:
          web:
            image: nginx:1.19
            ports:
              - "8080:80"
            environment:
              LOG_LEVEL: info
              APP_ENV: base
          db:
            image: postgres:13
            environment:
              POSTGRES_DB: myapp
        """
        
        let baseFile = tempDir.appendingPathComponent("docker-compose.yml")
        try baseYaml.write(to: baseFile, atomically: true, encoding: .utf8)
        
        // Override compose file
        let overrideYaml = """
        services:
          web:
            image: nginx:latest
            ports:
              - "9090:80"
            environment:
              LOG_LEVEL: debug
              DEBUG: "true"
          cache:
            image: redis:6
        """
        
        let overrideFile = tempDir.appendingPathComponent("docker-compose.override.yml")
        try overrideYaml.write(to: overrideFile, atomically: true, encoding: .utf8)
        
        // Parse multiple files
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: [baseFile, overrideFile])
        
        // Verify merged result
        #expect(composeFile.version == "3.8")
        #expect(composeFile.services.count == 3)
        
        // Check web service was properly overridden
        let webService = composeFile.services["web"]
        #expect(webService?.image == "nginx:latest")
        #expect(webService?.ports == ["9090:80"])
        #expect(webService?.environment?.asDictionary["LOG_LEVEL"] == "debug")
        #expect(webService?.environment?.asDictionary["DEBUG"] == "true")
        #expect(webService?.environment?.asDictionary["APP_ENV"] == "base")
        
        // Check db service was preserved
        let dbService = composeFile.services["db"]
        #expect(dbService?.image == "postgres:13")
        
        // Check cache service was added
        let cacheService = composeFile.services["cache"]
        #expect(cacheService?.image == "redis:6")
    }
    
    @Test
    func testParseThreeFiles() throws {
        // Create temporary directory for test files
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Base file
        let baseYaml = """
        version: '3.8'
        services:
          app:
            image: myapp:latest
            environment:
              ENV: base
              PORT: "8080"
        networks:
          default:
            driver: bridge
        """
        
        let baseFile = tempDir.appendingPathComponent("compose.base.yml")
        try baseYaml.write(to: baseFile, atomically: true, encoding: .utf8)
        
        // Dev file
        let devYaml = """
        services:
          app:
            environment:
              ENV: dev
              DEBUG: "true"
            ports:
              - "3000:8080"
        """
        
        let devFile = tempDir.appendingPathComponent("compose.dev.yml")
        try devYaml.write(to: devFile, atomically: true, encoding: .utf8)
        
        // Local file
        let localYaml = """
        services:
          app:
            environment:
              LOCAL_SETTING: "value"
            volumes:
              - ./src:/app/src
        """
        
        let localFile = tempDir.appendingPathComponent("compose.local.yml")
        try localYaml.write(to: localFile, atomically: true, encoding: .utf8)
        
        // Parse all three files
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: [baseFile, devFile, localFile])
        
        // Verify final merged result
        let appService = composeFile.services["app"]
        #expect(appService?.image == "myapp:latest")
        #expect(appService?.ports == ["3000:8080"])
        if let vols = appService?.volumes {
            #expect(vols.count == 1)
            if case .string(let v) = vols[0] { #expect(v == "./src:/app/src") } else { #expect(Bool(false)) }
        } else { #expect(Bool(false)) }
        
        let env = appService?.environment?.asDictionary
        #expect(env?["ENV"] == "dev") // Overridden by dev file
        #expect(env?["PORT"] == "8080") // From base
        #expect(env?["DEBUG"] == "true") // From dev
        #expect(env?["LOCAL_SETTING"] == "value") // From local
    }
    
    @Test
    func testParseNonExistentFile() throws {
        let parser = ComposeParser(log: log)
        let nonExistentFile = URL(fileURLWithPath: "/tmp/non-existent-compose.yml")

        #expect {
            _ = try parser.parse(from: [nonExistentFile])
        } throws: { error in
            guard let containerError = error as? ContainerizationError else { return false }
            return containerError.code == .notFound
        }
    }

    @Test
    func testSecurityValidations() throws {
        let parser = ComposeParser(log: log)

        // Test dangerous YAML content detection
        let dangerousYaml = """
        version: '3'
        services:
          test:
            image: nginx
            command: !!python/object/apply:subprocess.call
              - ["echo", "dangerous"]
        """

        #expect {
            _ = try parser.parse(from: dangerousYaml.data(using: .utf8)!)
        } throws: { error in
            guard let containerError = error as? ContainerizationError else { return false }
            return containerError.message.contains("unsafe YAML tag")
        }

        // Test invalid environment variable name
        let injectionYaml = """
        version: '3'
        services:
          test:
            image: nginx
            environment:
              - "INJECTED_VAR=${$(echo hacked)}"
        """

        #expect {
            _ = try parser.parse(from: injectionYaml.data(using: .utf8)!)
        } throws: { error in
            guard let containerError = error as? ContainerizationError else { return false }
            return containerError.message.contains("Invalid environment variable name")
        }
    }

    @Test
    func testFileSizeLimit() throws {
        let parser = ComposeParser(log: log)

        // Create a YAML string larger than 10MB
        let largeContent = String(repeating: "version: '3'\nservices:\n  test:\n    image: nginx\n", count: 200000)
        let largeData = largeContent.data(using: .utf8)!

        #expect {
            _ = try parser.parse(from: largeData)
        } throws: { error in
            guard let containerError = error as? ContainerizationError else { return false }
            return containerError.message.contains("too large")
        }
    }

    @Test
    func testEnvironmentVariableValidation() throws {
        let parser = ComposeParser(log: log)

        // Test valid environment variable names
        let validYaml = """
        version: '3'
        services:
          test:
            image: nginx
            environment:
              - "VALID_VAR=value"
              - "ANOTHER_VALID_123=value"
              - "_UNDERSCORE=value"
        """

        do {
            _ = try parser.parse(from: validYaml.data(using: .utf8)!)
        } catch {
            #expect(Bool(false), "Did not expect an error for valid environment variable names: \(error)")
        }

        // Test invalid environment variable names
        let invalidYaml = """
        version: '3'
        services:
          test:
            image: nginx
            environment:
              - "123INVALID=value"
              - "INVALID-CHAR=value"
              - "INVALID.SPACE=value"
        """

        do {
            _ = try parser.parse(from: invalidYaml.data(using: .utf8)!)
            #expect(Bool(false), "Expected invalid environment variable name error")
        } catch let error as ContainerizationError {
            #expect(error.message.contains("Invalid environment variable name"))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test
    func testYamlNestingDepthLimit() throws {
        let parser = ComposeParser(log: log)

        // Create deeply nested YAML
        var nestedYaml = "version: '3'\nservices:\n  test:\n    image: nginx\n"
        for i in 0..<25 {
            nestedYaml += String(repeating: "  ", count: i) + "nested:\n"
        }
        nestedYaml += String(repeating: "  ", count: 25) + "value: test\n"

        #expect {
            _ = try parser.parse(from: nestedYaml.data(using: .utf8)!)
        } throws: { error in
            guard let containerError = error as? ContainerizationError else { return false }
            return containerError.message.contains("nesting depth too deep")
        }
    }

    @Test
    func testAnchorsDisallowedByDefault() throws {
        let yaml = """
        version: '3'
        services:
          defaults: &defaults
            image: alpine
          app:
            <<: *defaults
            command: ["echo", "hello"]
        """

        let parser = ComposeParser(log: log)
        let data = yaml.data(using: .utf8)!
        #expect {
            _ = try parser.parse(from: data)
        } throws: { error in
            guard let containerError = error as? ContainerizationError else { return false }
            return containerError.message.contains("anchors")
        }
    }

    @Test
    func testAnchorsAllowedWithFlag() throws {
        let yaml = """
        version: '3'
        services:
          defaults: &defaults
            image: alpine
          app:
            <<: *defaults
            command: ["echo", "hello"]
        """

        let parser = ComposeParser(log: log, allowAnchors: true)
        let data = yaml.data(using: .utf8)!
        let composeFile = try parser.parse(from: data)
        #expect(composeFile.services["app"]?.image == "alpine")
    }
}
