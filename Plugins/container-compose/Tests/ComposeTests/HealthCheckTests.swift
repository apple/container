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
import ContainerizationError
import Logging
import Foundation
@testable import ComposeCore

struct HealthCheckTests {
    let log = Logger(label: "test")
    @Test func testHealthCheckParsing() throws {
        let yaml = """
        version: '3'
        services:
          web:
            image: nginx:alpine
            healthcheck:
              test: ["CMD", "curl", "-f", "http://localhost"]
              interval: 30s
              timeout: 10s
              retries: 3
              start_period: 40s
        """
        
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        #expect(composeFile.services["web"]?.healthcheck != nil)
        let healthcheck = composeFile.services["web"]!.healthcheck!
        
        #expect(healthcheck.test == .list(["CMD", "curl", "-f", "http://localhost"]))
        #expect(healthcheck.interval == "30s")
        #expect(healthcheck.timeout == "10s")
        #expect(healthcheck.retries == 3)
        #expect(healthcheck.startPeriod == "40s")
    }
    
    @Test func testHealthCheckStringFormat() throws {
        let yaml = """
        version: '3'
        services:
          app:
            image: alpine
            healthcheck:
              test: "curl -f http://localhost || exit 1"
        """
        
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let healthcheck = composeFile.services["app"]!.healthcheck!
        #expect(healthcheck.test == .string("curl -f http://localhost || exit 1"))
    }
    
    @Test func testHealthCheckDisabled() throws {
        let yaml = """
        version: '3'
        services:
          db:
            image: postgres
            healthcheck:
              disable: true
        """
        
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let healthcheck = composeFile.services["db"]!.healthcheck!
        #expect(healthcheck.disable ?? false)
    }
    
    @Test func testProjectConverterHealthCheck() throws {
        let yaml = """
        version: '3'
        services:
          web:
            image: nginx
            healthcheck:
              test: ["CMD", "wget", "-q", "--spider", "http://localhost"]
              interval: 30s
              timeout: 5s
              retries: 3
              start_period: 10s
        """
        
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "test"
        )
        
        let service = project.services["web"]!
        #expect(service.healthCheck != nil)
        
        let healthCheck = service.healthCheck!
        #expect(healthCheck.test == ["CMD", "wget", "-q", "--spider", "http://localhost"])
        #expect(healthCheck.interval == 30)
        #expect(healthCheck.timeout == 5)
        #expect(healthCheck.retries == 3)
        #expect(healthCheck.startPeriod == 10)
    }
    
    @Test func testHealthCheckWithShellFormat() throws {
        let yaml = """
        version: '3'
        services:
          api:
            image: node:alpine
            healthcheck:
              test: ["CMD-SHELL", "curl -f http://localhost:3000/health || exit 1"]
              interval: 10s
        """
        
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "test"
        )
        
        let healthCheck = project.services["api"]!.healthCheck!
        // CMD-SHELL should be converted to shell command
        #expect(healthCheck.test == ["/bin/sh", "-c", "curl -f http://localhost:3000/health || exit 1"])
    }
    
    @Test func testHealthCheckNoneDisabled() throws {
        let yaml = """
        version: '3'
        services:
          worker:
            image: busybox
            healthcheck:
              test: ["NONE"]
        """
        
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "test"
        )
        
        // NONE should result in no health check
        #expect(project.services["worker"]!.healthCheck == nil)
    }
    
    @Test func testProjectConverterHealthCheckStringToShell() throws {
        let yaml = """
        version: '3'
        services:
          api:
            image: busybox
            healthcheck:
              test: "echo ok"
        """
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(composeFile: composeFile, projectName: "test")
        let hc = try #require(project.services["api"]?.healthCheck)
        #expect(hc.test == ["/bin/sh", "-c", "echo ok"])
    }
}
