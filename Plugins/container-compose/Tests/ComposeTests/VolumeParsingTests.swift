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
}