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

class TestCLICompose: CLITest {
    
    func createComposeFile(content: String, filename: String = "docker-compose.yml") throws -> URL {
        let fileURL = testDir.appendingPathComponent(filename)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
    
    @Test func testComposeValidate() throws {
        let yaml = """
        version: '3'
        services:
          web:
            image: nginx:alpine
            ports:
              - "8080:80"
        """
        
        let composeFile = try createComposeFile(content: yaml)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
        let (output, error, status) = try run(
            arguments: ["compose", "-f", composeFile.path, "validate"],
            currentDirectory: testDir
        )
        
        #expect(status == 0)
        #expect(output.contains("valid"))
        #expect(error.isEmpty)
    }
    
    @Test func testComposeValidateInvalid() throws {
        let yaml = """
        version: '3'
        services:
          web:
            # Missing image
            ports:
              - "8080:80"
        """
        
        let composeFile = try createComposeFile(content: yaml)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
        let (_, error, status) = try run(
            arguments: ["compose", "-f", composeFile.path, "validate"],
            currentDirectory: testDir
        )
        
        #expect(status != 0)
        #expect(error.contains("Service 'web' must specify either 'image' or 'build'"))
    }
    
    @Test func testComposeUpDown() throws {
        // First pull the required image
        try doPull(imageName: alpine)
        
        let yaml = """
        version: '3'
        services:
          app:
            image: \(alpine)
            container_name: compose_test_app
            command: ["sleep", "300"]
        """
        
        let composeFile = try createComposeFile(content: yaml)
        defer { 
            try? FileManager.default.removeItem(at: testDir)
            // Cleanup any leftover containers
            try? run(arguments: ["rm", "-f", "compose_test_app"])
        }
        
        // Test compose up
        let (_, _, upStatus) = try run(
            arguments: ["compose", "-f", composeFile.path, "up", "-d"],
            currentDirectory: testDir
        )
        #expect(upStatus == 0)
        
        // Verify container is running
        let status = try getContainerStatus("compose_test_app")
        #expect(status == "running")
        
        // Test compose down
        let (_, _, downStatus) = try run(
            arguments: ["compose", "-f", composeFile.path, "down"],
            currentDirectory: testDir
        )
        #expect(downStatus == 0)
        
        // Verify container is removed
        #expect {
            _ = try getContainerStatus("compose_test_app")
        } throws: { _ in true }
    }
    
    @Test func testComposePs() throws {
        try doPull(imageName: alpine)
        
        let yaml = """
        version: '3'
        services:
          web:
            image: \(alpine)
            command: ["sleep", "300"]
          db:
            image: \(alpine)
            command: ["sleep", "300"]
        """
        
        let projectName = "testps"
        let composeFile = try createComposeFile(content: yaml)
        defer { 
            try? FileManager.default.removeItem(at: testDir)
            try? run(arguments: ["compose", "-p", projectName, "-f", composeFile.path, "down"])
        }
        
        // Start services
        let (_, _, upStatus) = try run(
            arguments: ["compose", "-p", projectName, "-f", composeFile.path, "up", "-d"],
            currentDirectory: testDir
        )
        #expect(upStatus == 0)
        
        // Test ps command
        let (output, _, psStatus) = try run(
            arguments: ["compose", "-p", projectName, "-f", composeFile.path, "ps"],
            currentDirectory: testDir
        )
        #expect(psStatus == 0)
        #expect(output.contains("web"))
        #expect(output.contains("db"))
        #expect(output.contains("running"))
    }
    
    @Test func testComposeWithDependencies() throws {
        try doPull(imageName: alpine)
        
        let yaml = """
        version: '3'
        services:
          db:
            image: \(alpine)
            command: ["sleep", "300"]
          app:
            image: \(alpine)
            command: ["sleep", "300"]
            depends_on:
              - db
        """
        
        let projectName = "testdeps"
        let composeFile = try createComposeFile(content: yaml)
        defer { 
            try? FileManager.default.removeItem(at: testDir)
            try? run(arguments: ["compose", "-p", projectName, "-f", composeFile.path, "down"])
        }
        
        // Start only app - should also start db
        let (_, _, status) = try run(
            arguments: ["compose", "-p", projectName, "-f", composeFile.path, "up", "-d", "app"],
            currentDirectory: testDir
        )
        #expect(status == 0)
        
        // Both containers should be running
        let dbStatus = try getContainerStatus("\(projectName)_db")
        let appStatus = try getContainerStatus("\(projectName)_app")
        #expect(dbStatus == "running")
        #expect(appStatus == "running")
    }
    
    @Test func testComposeStartStop() throws {
        try doPull(imageName: alpine)
        
        let yaml = """
        version: '3'
        services:
          app:
            image: \(alpine)
            command: ["sleep", "300"]
        """
        
        let projectName = "teststop"
        let composeFile = try createComposeFile(content: yaml)
        defer { 
            try? FileManager.default.removeItem(at: testDir)
            try? run(arguments: ["compose", "-p", projectName, "-f", composeFile.path, "down"])
        }
        
        // Start service
        let (_, _, upStatus) = try run(
            arguments: ["compose", "-p", projectName, "-f", composeFile.path, "up", "-d"],
            currentDirectory: testDir
        )
        #expect(upStatus == 0)
        
        // Stop service
        let (_, _, stopStatus) = try run(
            arguments: ["compose", "-p", projectName, "-f", composeFile.path, "stop"],
            currentDirectory: testDir
        )
        #expect(stopStatus == 0)
        
        // Container should exist but be stopped
        let container = try inspectContainer("\(projectName)_app")
        #expect(container.status != "running")
        
        // Start service again
        let (_, _, startStatus) = try run(
            arguments: ["compose", "-p", projectName, "-f", composeFile.path, "start"],
            currentDirectory: testDir
        )
        #expect(startStatus == 0)
        
        // Container should be running again
        let status = try getContainerStatus("\(projectName)_app")
        #expect(status == "running")
    }
    
    @Test func testComposeExec() throws {
        try doPull(imageName: alpine)
        
        let yaml = """
        version: '3'
        services:
          app:
            image: \(alpine)
            command: ["sleep", "300"]
            working_dir: /tmp
        """
        
        let projectName = "testexec"
        let composeFile = try createComposeFile(content: yaml)
        defer { 
            try? FileManager.default.removeItem(at: testDir)
            try? run(arguments: ["compose", "-p", projectName, "-f", composeFile.path, "down"])
        }
        
        // Start service
        let (_, _, upStatus) = try run(
            arguments: ["compose", "-p", projectName, "-f", composeFile.path, "up", "-d"],
            currentDirectory: testDir
        )
        #expect(upStatus == 0)
        
        // Execute command
        let (output, _, execStatus) = try run(
            arguments: ["compose", "-p", projectName, "-f", composeFile.path, "exec", "app", "pwd"],
            currentDirectory: testDir
        )
        #expect(execStatus == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp")
    }
    
    @Test func testComposeWithProfiles() throws {
        try doPull(imageName: alpine)
        
        let yaml = """
        version: '3.9'
        services:
          web:
            image: \(alpine)
            command: ["sleep", "300"]
            profiles: ["frontend"]
          api:
            image: \(alpine)
            command: ["sleep", "300"]
            profiles: ["backend"]
          db:
            image: \(alpine)
            command: ["sleep", "300"]
        """
        
        let projectName = "testprofiles"
        let composeFile = try createComposeFile(content: yaml)
        defer { 
            try? FileManager.default.removeItem(at: testDir)
            try? run(arguments: ["compose", "-p", projectName, "-f", composeFile.path, "down"])
        }
        
        // Start with frontend profile
        let (_, _, status) = try run(
            arguments: ["compose", "-p", projectName, "-f", composeFile.path, "--profile", "frontend", "up", "-d"],
            currentDirectory: testDir
        )
        #expect(status == 0)
        
        // Check what's running
        let dbStatus = try getContainerStatus("\(projectName)_db")
        let webStatus = try getContainerStatus("\(projectName)_web")
        #expect(dbStatus == "running") // No profile, always runs
        #expect(webStatus == "running") // Frontend profile
        
        // API should not be running
        #expect {
            _ = try getContainerStatus("\(projectName)_api")
        } throws: { _ in true }
    }

    @Test func testComposeUpWithRmFlag() throws {
        let yaml = """
        version: '3'
        services:
          test-service:
            image: alpine:latest
            command: ["sh", "-c", "echo 'Hello from test service' && sleep 1"]
        """

        let composeFile = try createComposeFile(content: yaml)
        let projectName = "test-rm"
        defer { try? FileManager.default.removeItem(at: testDir) }

        // Cleanup any leftover containers
        try? run(arguments: ["compose", "-p", projectName, "-f", composeFile.path, "down"], currentDirectory: testDir)

        // Test compose up with --rm flag
        let (_, _, upStatus) = try run(
            arguments: ["compose", "-p", projectName, "-f", composeFile.path, "up", "--rm"],
            currentDirectory: testDir
        )
        #expect(upStatus == 0)

        // Give the container time to exit
        Thread.sleep(forTimeInterval: 2)

        // Check that the container was automatically removed
        #expect {
            _ = try getContainerStatus("\(projectName)_test-service")
        } throws: { _ in true } // Should throw because container should be removed
    }
}
