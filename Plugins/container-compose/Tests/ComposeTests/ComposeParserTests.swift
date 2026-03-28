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
        name: my-stack
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
        #expect(composeFile.name == "my-stack")
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
        if case .string(let v0) = volumes[0] { #expect(v0 == "/host/path:/container/path") } else { #expect(Bool(false)) }
        if case .string(let v1) = volumes[1] { #expect(v1 == "/host/path2:/container/path2:ro") } else { #expect(Bool(false)) }
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
    func testParseIncludeShortSyntaxNormalizesIncludedPaths() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let packageDir = tempDir.appendingPathComponent("packages/api")
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootCompose = """
        services:
          web:
            image: nginx:latest
        include:
          - ./packages/api/compose.yaml
        """

        let childCompose = """
        services:
          api:
            build:
              context: .
              dockerfile: Dockerfile
            env_file:
              - ./api.env
            volumes:
              - ./data:/srv/data:ro
        """

        try rootCompose.write(to: tempDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try childCompose.write(to: packageDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: [tempDir.appendingPathComponent("compose.yaml")])

        let api = try #require(composeFile.services["api"])
        #expect(api.build?.context == packageDir.standardizedFileURL.path)
        #expect(api.build?.dockerfile == packageDir.appendingPathComponent("Dockerfile").standardizedFileURL.path)
        #expect(api.envFile == .list([packageDir.appendingPathComponent("api.env").standardizedFileURL.path]))
        #expect(api.volumes == [.string("\(packageDir.appendingPathComponent("data").standardizedFileURL.path):/srv/data:ro")])
    }

    @Test
    func testParseIncludeLongSyntaxUsesProjectDirectoryAndEnvFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vendorDir = tempDir.appendingPathComponent("vendor")
        let projectDir = vendorDir.appendingPathComponent("project")
        let configDir = vendorDir.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootCompose = """
        services:
          web:
            image: nginx:latest
        include:
          - path: ./vendor/compose.yaml
            project_directory: ./vendor/project
            env_file: ./vendor/config/include.env
        """

        let childCompose = """
        services:
          worker:
            image: ${WORKER_IMAGE:-busybox}
            build:
              context: .
        """

        try rootCompose.write(to: tempDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try childCompose.write(to: vendorDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try "WORKER_IMAGE=alpine:3.20\n".write(
            to: configDir.appendingPathComponent("include.env"),
            atomically: true,
            encoding: .utf8
        )

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: [tempDir.appendingPathComponent("compose.yaml")])

        let worker = try #require(composeFile.services["worker"])
        #expect(worker.image == "alpine:3.20")
        #expect(worker.build?.context == projectDir.standardizedFileURL.path)
    }

    @Test
    func testParseIncludeRejectsConflictingServiceNames() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let includeDir = tempDir.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        services:
          db:
            image: postgres:16
        include:
          - ./vendor/compose.yaml
        """.write(to: tempDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          db:
            image: mysql:8
          app:
            image: busybox
            depends_on:
              - db
        """.write(to: includeDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let parser = ComposeParser(log: log)
        #expect {
            _ = try parser.parse(from: [tempDir.appendingPathComponent("compose.yaml")])
        } throws: { error in
            guard let error = error as? ContainerizationError else { return false }
            return error.message.contains("service(s) already defined locally: db")
        }
    }

    @Test
    func testParseIncludeRejectsConflictingNetworkNames() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let includeDir = tempDir.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        services:
          web:
            image: nginx
            networks: [shared]
        networks:
          shared:
            driver: bridge
        include:
          - ./vendor/compose.yaml
        """.write(to: tempDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          api:
            image: busybox
            networks: [shared]
        networks:
          shared:
            external: true
        """.write(to: includeDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let parser = ComposeParser(log: log)
        #expect {
            _ = try parser.parse(from: [tempDir.appendingPathComponent("compose.yaml")])
        } throws: { error in
            guard let error = error as? ContainerizationError else { return false }
            return error.message.contains("network(s) already defined locally: shared")
        }
    }

    @Test
    func testParseIncludeRejectsConflictingVolumeNames() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let includeDir = tempDir.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        services:
          web:
            image: nginx
            volumes:
              - data:/data
        volumes:
          data: {}
        include:
          - ./vendor/compose.yaml
        """.write(to: tempDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          api:
            image: busybox
            volumes:
              - data:/cache
        volumes:
          data:
            name: other-data
        """.write(to: includeDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let parser = ComposeParser(log: log)
        #expect {
            _ = try parser.parse(from: [tempDir.appendingPathComponent("compose.yaml")])
        } throws: { error in
            guard let error = error as? ContainerizationError else { return false }
            return error.message.contains("volume(s) already defined locally: data")
        }
    }

    @Test
    func testParseIncludeEnvDefaultsReachServiceEnvFileExpansion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vendorDir = tempDir.appendingPathComponent("vendor")
        let configDir = vendorDir.appendingPathComponent("config")
        let appDir = vendorDir.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        services:
          web:
            image: nginx
        include:
          - path: ./vendor/compose.yaml
            env_file: ./vendor/config/include.env
        """.write(to: tempDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          app:
            image: busybox
            env_file:
              - ./app/app.env
        """.write(to: vendorDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try "DB_USER=alice\n".write(
            to: configDir.appendingPathComponent("include.env"),
            atomically: true,
            encoding: .utf8
        )
        try "DATABASE_URL=postgres://${DB_USER}@db\n".write(
            to: appDir.appendingPathComponent("app.env"),
            atomically: true,
            encoding: .utf8
        )

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: [tempDir.appendingPathComponent("compose.yaml")])
        let converter = ProjectConverter(log: log, projectDirectory: tempDir)
        let project = try converter.convert(composeFile: composeFile, projectName: "demo")

        let app = try #require(project.services["app"])
        #expect(app.environment["DATABASE_URL"] == "postgres://alice@db")
    }

    @Test
    func testParseIncludeEnvFileInterpolatesEarlierValues() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vendorDir = tempDir.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: vendorDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        include:
          - path: ./vendor/compose.yaml
            env_file: ./vendor/include.env
        services: {}
        """.write(to: tempDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          app:
            image: ${IMAGE}
        """.write(to: vendorDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try "BASE=alpine\nIMAGE=${BASE}\n".write(
            to: vendorDir.appendingPathComponent("include.env"),
            atomically: true,
            encoding: .utf8
        )

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: [tempDir.appendingPathComponent("compose.yaml")])
        let app = try #require(composeFile.services["app"])

        #expect(app.image == "alpine")
    }

    @Test
    func testParseIncludeEnvFileKeepsSingleQuotedLiterals() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vendorDir = tempDir.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: vendorDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let literalVariable = "COMPOSE_TEST_LITERAL_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"

        try """
        include:
          - path: ./vendor/compose.yaml
            env_file: ./vendor/include.env
        services: {}
        """.write(to: tempDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          app:
            image: ${IMAGE}
        """.write(to: vendorDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try "IMAGE='${\(literalVariable)}/app:latest'\n".write(
            to: vendorDir.appendingPathComponent("include.env"),
            atomically: true,
            encoding: .utf8
        )

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: [tempDir.appendingPathComponent("compose.yaml")])
        let app = try #require(composeFile.services["app"])

        #expect(app.image == "${\(literalVariable)}/app:latest")
    }

    @Test
    func testParseFilePreservesServiceNetworkMode() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        services:
          app:
            image: nginx:latest
            network_mode: bridge
        networks:
          appnet:
            driver: bridge
        """.write(to: tempDir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: [tempDir.appendingPathComponent("compose.yaml")])
        let app = try #require(composeFile.services["app"])

        #expect(app.networkMode == "bridge")
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
    func testVariableInterpolationSupportsEmptyDashDefault() throws {
        let parser = ComposeParser(log: log)
        let uniqueVariable = "COMPOSE_TEST_UNSET_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let yaml = """
        version: '3'
        services:
          app:
            image: alpine
            environment:
              - DATA_DIR=${\(uniqueVariable)-}
              - GIT_DIR=${MAIN_GIT_DIR:-$PWD/.git}
        """

        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        guard case let .list(environment)? = composeFile.services["app"]?.environment else {
            Issue.record("Expected list environment")
            return
        }

        #expect(environment.contains("DATA_DIR="))
        #expect(environment.contains(where: { $0.hasPrefix("GIT_DIR=") }))
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
