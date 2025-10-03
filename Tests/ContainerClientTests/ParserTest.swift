//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerClient

struct ParserTest {
    @Test
    func testPublishPortParserTcp() throws {
        let result = try Parser.publishPorts(["127.0.0.1:8080:8000/tcp"])
        #expect(result.count == 1)
        #expect(result[0].hostAddress == "127.0.0.1")
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(8000))
        #expect(result[0].proto == .tcp)
    }

    @Test
    func testPublishPortParserUdp() throws {
        let result = try Parser.publishPorts(["192.168.32.36:8000:8080/UDP"])
        #expect(result.count == 1)
        #expect(result[0].hostAddress == "192.168.32.36")
        #expect(result[0].hostPort == UInt16(8000))
        #expect(result[0].containerPort == UInt16(8080))
        #expect(result[0].proto == .udp)
    }

    @Test
    func testPublishPortNoHostAddress() throws {
        let result = try Parser.publishPorts(["8080:8000/tcp"])
        #expect(result.count == 1)
        #expect(result[0].hostAddress == "0.0.0.0")
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(8000))
        #expect(result[0].proto == .tcp)
    }

    @Test
    func testPublishPortNoProtocol() throws {
        let result = try Parser.publishPorts(["8080:8000"])
        #expect(result.count == 1)
        #expect(result[0].hostAddress == "0.0.0.0")
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(8000))
        #expect(result[0].proto == .tcp)
    }

    @Test
    func testPublishPortInvalidProtocol() throws {
        #expect {
            _ = try Parser.publishPorts(["8080:8000/sctp"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish protocol")
        }
    }

    @Test
    func testPublishPortInvalidValue() throws {
        #expect {
            _ = try Parser.publishPorts([""])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish value")
        }
    }

    @Test
    func testPublishPortInvalidAddress() throws {
        #expect {
            _ = try Parser.publishPorts(["1234"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish address")
        }
    }

    @Test
    func testPublishPortInvalidHostPort() throws {
        #expect {
            _ = try Parser.publishPorts(["foo:1234"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish host port")
        }
    }

    @Test
    func testPublishPortInvalidContainerPort() throws {
        #expect {
            _ = try Parser.publishPorts(["1234:foo"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testMountBindRelativePath() throws {

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-bind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let originalDir = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(tempDir.path)
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalDir)
        }

        let result = try Parser.mount("type=bind,src=.,dst=/foo")

        switch result {
        case .filesystem(let fs):
            let expectedPath = URL(filePath: ".").absoluteURL.path
            #expect(fs.source == expectedPath)
            #expect(fs.destination == "/foo")
            #expect(!fs.isVolume)
        case .volume:
            #expect(Bool(false), "Expected filesystem mount, got volume")
        }
    }

    @Test
    func testMountBindAbsolutePath() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-bind-abs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let result = try Parser.mount("type=bind,src=\(tempDir.path),dst=/foo")

        switch result {
        case .filesystem(let fs):
            #expect(fs.source == tempDir.path)
            #expect(fs.destination == "/foo")
            #expect(!fs.isVolume)
        case .volume:
            #expect(Bool(false), "Expected filesystem mount, got volume")
        }
    }

    @Test
    func testMountVolumeValidName() throws {
        let result = try Parser.mount("type=volume,src=myvolume,dst=/data")

        switch result {
        case .filesystem:
            #expect(Bool(false), "Expected volume mount, got filesystem")
        case .volume(let vol):
            #expect(vol.name == "myvolume")
            #expect(vol.destination == "/data")
        }
    }

    @Test
    func testMountVolumeInvalidName() throws {
        #expect {
            _ = try Parser.mount("type=volume,src=.,dst=/data")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("Invalid volume name")
        }
    }

    @Test
    func testMountBindNonExistentPath() throws {
        #expect {
            _ = try Parser.mount("type=bind,src=/nonexistent/path,dst=/foo")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("path") && error.description.contains("does not exist")
        }
    }

    @Test
    func testMountBindFileInsteadOfDirectory() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test-file-\(UUID().uuidString)")
        try "test content".write(to: tempFile, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        #expect {
            _ = try Parser.mount("type=bind,src=\(tempFile.path),dst=/foo")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("path") && error.description.contains("is not a directory")
        }
    }

    @Test
    func testIsValidDomainNameOk() throws {
        let names = [
            "a",
            "a.b",
            "foo.bar",
            "F-O.B-R",
            [
                String(repeating: "0", count: 63),
                String(repeating: "1", count: 63),
                String(repeating: "2", count: 63),
                String(repeating: "3", count: 63),
            ].joined(separator: "."),
        ]
        for name in names {
            #expect(Parser.isValidDomainName(name))
        }
    }

    @Test
    func testIsValidDomainNameBad() throws {
        let names = [
            ".foo",
            "foo.",
            ".foo.bar",
            "foo.bar.",
            "-foo.bar",
            "foo.bar-",
            [
                String(repeating: "0", count: 63),
                String(repeating: "1", count: 63),
                String(repeating: "2", count: 63),
                String(repeating: "3", count: 62),
                "4",
            ].joined(separator: "."),
        ]
        for name in names {
            #expect(!Parser.isValidDomainName(name))
        }
    }
}
