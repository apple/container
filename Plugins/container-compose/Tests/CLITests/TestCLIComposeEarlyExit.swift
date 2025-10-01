//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
//===----------------------------------------------------------------------===//

import Foundation
import Testing

class TestCLIComposeEarlyExit: CLITest {

    private func writeCompose(_ yaml: String, name: String = "docker-compose.yml") throws -> URL {
        let url = testDir.appendingPathComponent(name)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func testUpNoServicesMatchProfiles() throws {
        let yaml = """
        version: '3'
        services:
          web:
            image: alpine
            profiles: [prod]
        """
        let file = try writeCompose(yaml)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let (out, err, status) = try run(arguments: ["compose","-f",file.path,"up","--profile","dev"], currentDirectory: testDir)
        #expect(status == 0)
        #expect(out.contains("No services matched the provided filters. Nothing to start."))
        #expect(err.isEmpty)
    }

    @Test func testStartNoServicesMatchProfiles() throws {
        let yaml = """
        version: '3'
        services:
          api:
            image: alpine
            profiles: [prod]
        """
        let file = try writeCompose(yaml)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let (out, err, status) = try run(arguments: ["compose","-f",file.path,"start","--profile","dev"], currentDirectory: testDir)
        #expect(status == 0)
        #expect(out.contains("Nothing to start."))
        #expect(err.isEmpty)
    }

    @Test func testStopNoServicesMatchProfiles() throws {
        let yaml = """
        version: '3'
        services:
          api:
            image: alpine
            profiles: [prod]
        """
        let file = try writeCompose(yaml)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let (out, err, status) = try run(arguments: ["compose","-f",file.path,"stop","--profile","dev"], currentDirectory: testDir)
        #expect(status == 0)
        #expect(out.contains("Nothing to stop."))
        #expect(err.isEmpty)
    }

    @Test func testRestartNoServicesMatchProfiles() throws {
        let yaml = """
        version: '3'
        services:
          api:
            image: alpine
            profiles: [prod]
        """
        let file = try writeCompose(yaml)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let (out, err, status) = try run(arguments: ["compose","-f",file.path,"restart","--profile","dev"], currentDirectory: testDir)
        #expect(status == 0)
        #expect(out.contains("Nothing to restart."))
        #expect(err.isEmpty)
    }
}

