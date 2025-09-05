//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
//===----------------------------------------------------------------------===//

import Testing
import Logging
@testable import ComposeCore

struct MemoryLimitTests {
    let log = Logger(label: "test")

    @Test func testMemLimitStringPropagates() throws {
        let yaml = """
        version: '3'
        services:
          web:
            image: alpine
            mem_limit: "2g"
        """

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)

        let converter = ProjectConverter(log: log)
        let project = try converter.convert(composeFile: composeFile, projectName: "mtest")

        #expect(project.services["web"]?.memory == "2g")
    }

    @Test func testMemLimitMaxPropagates() throws {
        let yaml = """
        version: '3'
        services:
          api:
            image: alpine
            mem_limit: "max"
        """

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)

        let project = try ProjectConverter(log: log).convert(composeFile: composeFile, projectName: "mtest")
        #expect(project.services["api"]?.memory == "max")
    }
}

