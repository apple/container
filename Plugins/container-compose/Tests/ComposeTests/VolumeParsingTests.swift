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

import Testing
import ComposeCore
import Logging
import Foundation
@testable import ComposeCore

struct VolumeParsingTests {
    let log = Logger(label: "test")
    
    @Test func testEmptyVolumeDefinition() throws {
        // Test case for volumes defined with empty values (e.g., "postgres-data:")
        let yaml = """
        version: '3'
        services:
          db:
            image: postgres
            volumes:
              - postgres-data:/var/lib/postgresql/data
        volumes:
          postgres-data:
          redis-data:
        """
        
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        #expect(composeFile.volumes != nil)
        #expect(composeFile.volumes?.count == 2)
        
        // Check that empty volume definitions are parsed correctly
        let postgresVolume = composeFile.volumes?["postgres-data"]
        #expect(postgresVolume != nil)
        #expect(postgresVolume?.driver == nil)
        #expect(postgresVolume?.external == nil)
        #expect(postgresVolume?.name == nil)
        
        let redisVolume = composeFile.volumes?["redis-data"]
        #expect(redisVolume != nil)
        #expect(redisVolume?.driver == nil)
        #expect(redisVolume?.external == nil)
        #expect(redisVolume?.name == nil)
    }
    
    @Test func testVolumeWithProperties() throws {
        let yaml = """
        version: '3'
        services:
          db:
            image: postgres
            volumes:
              - data:/var/lib/postgresql/data
        volumes:
          data:
            driver: local
            name: my-data-volume
        """
        
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        #expect(composeFile.volumes != nil)
        #expect(composeFile.volumes?.count == 1)
        
        let dataVolume = composeFile.volumes?["data"]
        #expect(dataVolume != nil)
        #expect(dataVolume?.driver == "local")
        #expect(dataVolume?.name == "my-data-volume")
        #expect(dataVolume?.external == nil)
    }
    
    @Test func testExternalVolume() throws {
        let yaml = """
        version: '3'
        services:
          app:
            image: myapp
            volumes:
              - external-vol:/data
        volumes:
          external-vol:
            external: true
        """
        
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let externalVolume = composeFile.volumes?["external-vol"]
        #expect(externalVolume != nil)
        #expect(externalVolume?.external != nil)
    }
    
    @Test func testVolumeMountParsing() throws {
        // Test parsing of volume mount specifications
        let bindMount = VolumeMount(from: "./data:/app/data")
        #expect(bindMount != nil)
        #expect(bindMount?.type == .bind)
        #expect(bindMount?.source == "./data")
        #expect(bindMount?.target == "/app/data")
        #expect(bindMount?.readOnly == false)
        
        let namedVolume = VolumeMount(from: "my-volume:/data")
        #expect(namedVolume != nil)
        #expect(namedVolume?.type == .volume)
        #expect(namedVolume?.source == "my-volume")
        #expect(namedVolume?.target == "/data")
        #expect(namedVolume?.readOnly == false)
        
        let readOnlyVolume = VolumeMount(from: "my-volume:/data:ro")
        #expect(readOnlyVolume != nil)
        #expect(readOnlyVolume?.type == .volume)
        #expect(readOnlyVolume?.readOnly == true)
        
        let absolutePath = VolumeMount(from: "/host/path:/container/path")
        #expect(absolutePath != nil)
        #expect(absolutePath?.type == .bind)
        #expect(absolutePath?.source == "/host/path")
    }

    @Test func testBindPathNormalization() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = FileManager.default.currentDirectoryPath
        let yaml = """
        services:
          app:
            image: alpine:latest
            volumes:
              - "./data:/app/data"
              - "~/tmp:/app/tmp"
        """
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(composeFile: composeFile, projectName: "proj", profiles: [], selectedServices: [])
        let svc = try #require(project.services["app"]) 
        let v1 = try #require(svc.volumes.first { $0.target == "/app/data" })
        #expect(v1.type == .bind)
        #expect(v1.source == URL(fileURLWithPath: cwd).appendingPathComponent("data").standardized.path)
        let v2 = try #require(svc.volumes.first { $0.target == "/app/tmp" })
        #expect(v2.type == .bind)
        #expect(v2.source == URL(fileURLWithPath: home).appendingPathComponent("tmp").standardized.path)
    }

    @Test func testAnonymousVolumeShortForm() throws {
        // Bare "/path" in service volumes should be treated as an anonymous volume
        let yaml = """
        services:
          app:
            image: alpine:latest
            volumes:
              - "/data"
        """

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(composeFile: composeFile, projectName: "test-project", profiles: [], selectedServices: [])
        let svc = try #require(project.services["app"])
        let m = try #require(svc.volumes.first)
        #expect(m.type == .volume)
        #expect(m.source.isEmpty) // anonymous; orchestrator will generate a name
        #expect(m.target == "/data")
    }
    
    @Test func testProjectConversionWithVolumes() throws {
        let yaml = """
        version: '3'
        services:
          db:
            image: postgres
            volumes:
              - postgres-data:/var/lib/postgresql/data
              - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
          cache:
            image: redis
            volumes:
              - redis-data:/data
        volumes:
          postgres-data:
            driver: local
          redis-data:
        """
        
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "test-project",
            profiles: [],
            selectedServices: []
        )
        
        // Check volumes are properly converted
        #expect(project.volumes.count == 2)
        #expect(project.volumes["postgres-data"] != nil)
        #expect(project.volumes["postgres-data"]?.driver == "local")
        #expect(project.volumes["redis-data"] != nil)
        #expect(project.volumes["redis-data"]?.driver == "local") // Default driver
        
        // Check service volume mounts
        let dbService = project.services["db"]
        #expect(dbService != nil)
        #expect(dbService?.volumes.count == 2)
        
        // Find the named volume mount
        let namedVolumeMount = dbService?.volumes.first { $0.type == .volume }
        #expect(namedVolumeMount != nil)
        #expect(namedVolumeMount?.source == "postgres-data")
        #expect(namedVolumeMount?.target == "/var/lib/postgresql/data")
        
        // Find the bind mount
        let bindMount = dbService?.volumes.first { $0.type == .bind }
        #expect(bindMount != nil)
        #expect(bindMount?.readOnly == true)
    }
}
