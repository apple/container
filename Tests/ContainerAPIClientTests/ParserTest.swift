//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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
import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerAPIClient

struct ParserTest {
    @Test
    func testPublishPortParserTcp() throws {
        let result = try Parser.publishPorts(["127.0.0.1:8080:8000/tcp"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("127.0.0.1")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(8000))
        #expect(result[0].proto == .tcp)
        #expect(result[0].count == 1)
    }

    @Test
    func testPublishPortParserUdp() throws {
        let result = try Parser.publishPorts(["192.168.32.36:8000:8080/UDP"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("192.168.32.36")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8000))
        #expect(result[0].containerPort == UInt16(8080))
        #expect(result[0].proto == .udp)
        #expect(result[0].count == 1)
    }

    @Test
    func testPublishPortRange() throws {
        let result = try Parser.publishPorts(["127.0.0.1:8080-8179:9000-9099/tcp"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("127.0.0.1")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(9000))
        #expect(result[0].proto == .tcp)
        #expect(result[0].count == 100)
    }

    @Test
    func testPublishPortRangeSingle() throws {
        let result = try Parser.publishPorts(["127.0.0.1:8080-8080:9000-9000/tcp"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("127.0.0.1")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(9000))
        #expect(result[0].proto == .tcp)
        #expect(result[0].count == 1)
    }

    @Test
    func testPublishPortNoHostAddress() throws {
        let result = try Parser.publishPorts(["8080:8000/tcp"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("0.0.0.0")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(8000))
        #expect(result[0].proto == .tcp)
        #expect(result[0].count == 1)
    }

    @Test
    func testPublishPortNoProtocol() throws {
        let result = try Parser.publishPorts(["8080:8000"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("0.0.0.0")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(8000))
        #expect(result[0].proto == .tcp)
        #expect(result[0].count == 1)
    }

    @Test
    func testPublishPortParserIPv6() throws {
        let result = try Parser.publishPorts(["[fe80::36f3:5e50:ed71:1bb]:8080:8000/tcp"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("fe80::36f3:5e50:ed71:1bb")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(8000))
        #expect(result[0].proto == .tcp)
        #expect(result[0].count == 1)
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
    func testPublishPortMissingPort() throws {
        #expect {
            _ = try Parser.publishPorts(["1234"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish value")
        }
    }

    @Test
    func testPublishInvalidIPv4Address() throws {
        #expect {
            _ = try Parser.publishPorts(["1234:8080:8000"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish IPv4 address")
        }
    }

    @Test
    func testPublishInvalidIPv6Address() throws {
        #expect {
            _ = try Parser.publishPorts([
                "[1234:5678]:8080:8000",
                "[2001::db8::1]:8080:8080",
                "[2001:db8:85a3::8a2e:370g:7334]:8080:8080",
                "[2001:db8:85a3::][8a2e::7334]:8080:8080",
            ])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish IPv6 address")
        }
    }

    @Test
    func testPublishPortInvalidHostPort() throws {
        #expect {
            _ = try Parser.publishPorts(["65536:1234"])
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
            _ = try Parser.publishPorts(["1234:65536"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testPublishPortRangeMismatch() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8000:9000-9001"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("counts are not equal")
        }
    }

    @Test
    func testPublishPortRangeInvalidHostPortStart() throws {
        #expect {
            _ = try Parser.publishPorts(["65536-65537:9000-9001"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish host port")
        }
    }

    @Test
    func testPublishPortRangeZeroHostPortStart() throws {
        #expect {
            _ = try Parser.publishPorts(["0-1:9000-9001"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish host port")
        }
    }

    @Test
    func testPublishPortRangeInvalidHostPortEnd() throws {
        #expect {
            _ = try Parser.publishPorts(["65535-65536:9000-9001"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish host port")
        }
    }

    @Test
    func testPublishPortRangeInvalidHostPortRange() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8001-8002:9000-9001"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish host port")
        }
    }

    @Test
    func testPublishPortRangeNegativeHostPortRange() throws {
        #expect {
            _ = try Parser.publishPorts(["8001-8000:9000-9001"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish host port")
        }
    }

    @Test
    func testPublishPortRangeInvalidContainerPortStart() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8001:65536-65537"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testPublishPortRangeZeroContainerPortStart() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8001:0-1"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testPublishPortRangeInvalidContainerPortEnd() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8001:65535-65536"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testPublishPortRangeInvalidContainerPortRange() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8001:9000-9001-9002"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testPublishPortRangeNegativeContainerPortRange() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8001:9001-9000"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testRelativePaths() throws {
        let originalDir = FileManager.default.currentDirectoryPath
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalDir)
        }

        func realpath(_ path: String) -> String {
            let resolved = UnsafeMutablePointer<CChar>.allocate(capacity: Int(PATH_MAX))
            defer { resolved.deallocate() }
            guard let result = Darwin.realpath(path, resolved) else {
                return path
            }
            return String(cString: result)
        }

        // Test bind mount with relative path "."
        do {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-bind-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            FileManager.default.changeCurrentDirectoryPath(tempDir.path)
            let result = try Parser.mount("type=bind,src=.,dst=/foo")

            switch result {
            case .filesystem(let fs):
                #expect(fs.source == realpath(tempDir.path))
                #expect(fs.destination == "/foo")
                #expect(!fs.isVolume)
            case .volume:
                #expect(Bool(false), "Expected filesystem mount, got volume")
            }
        }

        // Test volume with relative path "./"
        do {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-volume-rel-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            FileManager.default.changeCurrentDirectoryPath(tempDir.path)
            let result = try Parser.volume("./:/foo")

            switch result {
            case .filesystem(let fs):
                let expectedPath = realpath(tempDir.path)
                // Normalize trailing slashes for comparison
                #expect(fs.source.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                #expect(fs.destination == "/foo")
            case .volume:
                #expect(Bool(false), "Expected filesystem mount, got volume")
            }
        }

        // Test volume with nested relative path "./subdir"
        do {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-volume-rel-nested-\(UUID().uuidString)")
            let nestedDir = tempDir.appendingPathComponent("subdir")
            try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            FileManager.default.changeCurrentDirectoryPath(tempDir.path)
            let result = try Parser.volume("./subdir:/foo")

            switch result {
            case .filesystem(let fs):
                let expectedPath = realpath(nestedDir.path)
                // Normalize trailing slashes for comparison
                #expect(fs.source.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                #expect(fs.destination == "/foo")
            case .volume:
                #expect(Bool(false), "Expected filesystem mount, got volume")
            }
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
            return error.description.contains("invalid volume name")
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

    // MARK: - Environment Variable Tests

    @Test
    func testEnvExplicitValue() throws {
        let result = Parser.env(envList: ["FOO=bar", "BAZ=qux"])
        #expect(result == ["FOO=bar", "BAZ=qux"])
    }

    @Test
    func testEnvImplicitInheritance() throws {
        guard let homeValue = ProcessInfo.processInfo.environment["PATH"] else {
            Issue.record("PATH environment variable not set")
            return
        }

        let result = Parser.env(envList: ["PATH"])
        #expect(result == ["PATH=\(homeValue)"])
    }

    @Test
    func testEnvImplicitUndefinedVariable() throws {
        // A variable that doesn't exist should be silently skipped
        let result = Parser.env(envList: ["THIS_VAR_DEFINITELY_DOES_NOT_EXIST_12345"])
        #expect(result.isEmpty)
    }

    @Test
    func testEnvMixedExplicitAndImplicit() throws {
        guard let homeValue = ProcessInfo.processInfo.environment["HOME"] else {
            Issue.record("HOME environment variable not set")
            return
        }

        let result = Parser.env(envList: ["FOO=bar", "HOME", "BAZ=qux"])
        #expect(result == ["FOO=bar", "HOME=\(homeValue)", "BAZ=qux"])
    }

    @Test
    func testEnvEmptyValue() throws {
        // Explicit empty value should be preserved
        let result = Parser.env(envList: ["EMPTY="])
        #expect(result == ["EMPTY="])
    }

    private func tmpFileWithContent(_ content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("envfile-test-\(UUID().uuidString)")
        try content.write(to: tempFile, atomically: true, encoding: .utf8)
        return tempFile
    }

    // NOTE: A lot of these env-file tests are recreations of the docker cli's unit tests for their
    // env-file support.

    @Test
    func testParseEnvFileGoodFile() throws {
        var content = """
            foo=bar
                baz=quux
            # comment

            _foobar=foobaz
            with.dots=working
            and_underscore=working too
            """
        content += "\n    \t  "

        let tmpFile = try tmpFileWithContent(content)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let lines = try Parser.envFile(path: tmpFile.path)

        let expectedLines = [
            "foo=bar",
            "baz=quux",
            "_foobar=foobaz",
            "with.dots=working",
            "and_underscore=working too",
        ]

        #expect(lines == expectedLines)
    }

    @Test
    func testParseEnvFileMultipleEqualsSigns() throws {
        let content = """
            URL=https://foo.bar?baz=woo
            """
        let tmpFile = try tmpFileWithContent(content)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let lines = try Parser.envFile(path: tmpFile.path)

        let expectedLines = [
            "URL=https://foo.bar?baz=woo"
        ]

        #expect(lines == expectedLines)
    }

    @Test
    func testParseEnvFileEmptyFile() throws {
        let tmpFile = try tmpFileWithContent("")
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let lines = try Parser.envFile(path: tmpFile.path)
        #expect(lines.isEmpty)
    }

    @Test
    func testParseEnvFileNonExistentFile() throws {
        #expect {
            _ = try Parser.envFile(path: "/nonexistent/foo_bar_baz")
        } throws: { error in
            guard let error = error as? ContainerizationError,
                let cause = error.cause
            else {
                return false
            }
            return String(describing: cause).contains("No such file or directory")
        }
    }

    @Test
    func testParseEnvFileBadlyFormattedFile() throws {
        let content = """
            foo=bar
                f   =quux
            """
        let tmpFile = try tmpFileWithContent(content)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        #expect {
            _ = try Parser.envFile(path: tmpFile.path)
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("contains whitespaces")
        }
    }

    @Test
    func testParseEnvFileRandomFile() throws {
        let content = """
            first line
            another invalid line
            """
        let tmpFile = try tmpFileWithContent(content)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        #expect {
            _ = try Parser.envFile(path: tmpFile.path)
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("first line") && error.description.contains("contains whitespaces")
        }
    }

    @Test
    func testParseEnvVariableDefinitionsFile() throws {
        let content = """
            # comment=
            UNDEFINED_VAR
            HOME
            """
        let tmpFile = try tmpFileWithContent(content)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let variables = try Parser.envFile(path: tmpFile.path)

        // HOME should be imported from environment
        guard let homeValue = ProcessInfo.processInfo.environment["HOME"] else {
            Issue.record("HOME environment variable not set")
            return
        }

        #expect(variables.count == 1)
        #expect(variables[0] == "HOME=\(homeValue)")
    }

    @Test
    func testParseEnvVariableWithNoNameFile() throws {
        let content = """
            # comment=
            =blank variable names are an error case
            """
        let tmpFile = try tmpFileWithContent(content)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        #expect {
            _ = try Parser.envFile(path: tmpFile.path)
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("no variable name")
        }
    }

    @Test
    func testParseEnvFileFromNamedPipe() throws {
        let pipePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("envfile-pipe-\(UUID().uuidString)")

        // Create a named pipe (FIFO)
        let result = mkfifo(pipePath.path, 0o600)
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
        defer { try? FileManager.default.removeItem(at: pipePath) }

        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            do {
                let handle = try FileHandle(forWritingTo: pipePath)
                try handle.write(contentsOf: "SECRET_KEY=value123\n".data(using: .utf8)!)
                try handle.close()
            } catch {
                Issue.record(error)
            }
            group.leave()
        }

        // Read from pipe (blocks until writer connects)
        let lines = try Parser.envFile(path: pipePath.path)

        // Wait for write to complete
        group.wait()

        #expect(lines == ["SECRET_KEY=value123"])
    }

    // MARK: Network Parser Tests

    @Test
    func testParseNetworkSimpleName() throws {
        let result = try Parser.network("default")
        #expect(result.name == "default")
        #expect(result.macAddress == nil)
    }

    @Test
    func testParseNetworkWithMACAddress() throws {
        let result = try Parser.network("backend,mac=02:42:ac:11:00:02")
        #expect(result.name == "backend")
        #expect(result.macAddress == "02:42:ac:11:00:02")
    }

    @Test
    func testParseNetworkWithMACAddressHyphenSeparator() throws {
        let result = try Parser.network("backend,mac=02-42-ac-11-00-02")
        #expect(result.name == "backend")
        #expect(result.macAddress == "02-42-ac-11-00-02")
    }

    @Test
    func testParseNetworkEmptyString() throws {
        #expect {
            _ = try Parser.network("")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("network specification cannot be empty")
        }
    }

    @Test
    func testParseNetworkEmptyName() throws {
        #expect {
            _ = try Parser.network(",mac=02:42:ac:11:00:02")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("network name cannot be empty")
        }
    }

    @Test
    func testParseNetworkEmptyMACAddress() throws {
        #expect {
            _ = try Parser.network("backend,mac=")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("mac address value cannot be empty")
        }
    }

    @Test
    func testParseNetworkUnknownProperty() throws {
        #expect {
            _ = try Parser.network("backend,unknown=value")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("unknown network property") && error.description.contains("unknown")
        }
    }

    @Test
    func testParseNetworkInvalidPropertyFormat() throws {
        #expect {
            _ = try Parser.network("backend,invalidproperty")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid property format")
        }
    }

    // MARK: - Relative Path Passthrough Tests

    @Test
    func testProcessEntrypointRelativePathPassthrough() throws {
        let processFlags = try Flags.Process.parse(["--cwd", "/bin"])
        let managementFlags = try Flags.Management.parse(["--entrypoint", "./uname"])

        let result = try Parser.process(
            arguments: [],
            processFlags: processFlags,
            managementFlags: managementFlags,
            config: nil
        )

        #expect(result.executable == "./uname")
        #expect(result.workingDirectory == "/bin")
    }

    @Test
    func testUlimitParserSoftAndHard() throws {
        let result = try Parser.rlimits(["nofile=1024:2048"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_NOFILE")
        #expect(result[0].soft == 1024)
        #expect(result[0].hard == 2048)
    }

    @Test
    func testUlimitParserSingleValue() throws {
        let result = try Parser.rlimits(["nproc=512"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_NPROC")
        #expect(result[0].soft == 512)
        #expect(result[0].hard == 512)
    }

    @Test
    func testUlimitParserUnlimited() throws {
        let result = try Parser.rlimits(["memlock=unlimited"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_MEMLOCK")
        #expect(result[0].soft == UInt64.max)
        #expect(result[0].hard == UInt64.max)
    }

    @Test
    func testUlimitParserUnlimitedHardOnly() throws {
        let result = try Parser.rlimits(["stack=8192:unlimited"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_STACK")
        #expect(result[0].soft == 8192)
        #expect(result[0].hard == UInt64.max)
    }

    @Test
    func testUlimitParserMinusOneAsUnlimited() throws {
        let result = try Parser.rlimits(["core=-1"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_CORE")
        #expect(result[0].soft == UInt64.max)
        #expect(result[0].hard == UInt64.max)
    }

    @Test
    func testUlimitParserMultipleUlimits() throws {
        let result = try Parser.rlimits(["nofile=1024:2048", "nproc=256", "cpu=60:120"])
        #expect(result.count == 3)
        #expect(result[0].limit == "RLIMIT_NOFILE")
        #expect(result[1].limit == "RLIMIT_NPROC")
        #expect(result[2].limit == "RLIMIT_CPU")
    }

    @Test
    func testUlimitParserAllSupportedTypes() throws {
        let types = ["core", "cpu", "data", "fsize", "memlock", "nofile", "nproc", "rss", "stack"]
        let expectedRlimits = [
            "RLIMIT_CORE", "RLIMIT_CPU", "RLIMIT_DATA", "RLIMIT_FSIZE",
            "RLIMIT_MEMLOCK", "RLIMIT_NOFILE", "RLIMIT_NPROC", "RLIMIT_RSS", "RLIMIT_STACK",
        ]

        for (i, type) in types.enumerated() {
            let result = try Parser.rlimits(["\(type)=100"])
            #expect(result.count == 1)
            #expect(result[0].limit == expectedRlimits[i])
        }
    }

    @Test
    func testUlimitParserCaseInsensitive() throws {
        let result = try Parser.rlimits(["NOFILE=1024", "Nproc=512"])
        #expect(result.count == 2)
        #expect(result[0].limit == "RLIMIT_NOFILE")
        #expect(result[1].limit == "RLIMIT_NPROC")
    }

    @Test
    func testUlimitParserInvalidFormat() throws {
        #expect {
            _ = try Parser.rlimits(["nofile"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid ulimit format")
        }
    }

    @Test
    func testUlimitParserUnsupportedType() throws {
        #expect {
            _ = try Parser.rlimits(["foo=100"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("unsupported ulimit type")
        }
    }

    @Test
    func testUlimitParserSoftExceedsHard() throws {
        #expect {
            _ = try Parser.rlimits(["nofile=2048:1024"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("soft limit") && error.description.contains("cannot exceed hard limit")
        }
    }

    @Test
    func testUlimitParserDuplicateType() throws {
        #expect {
            _ = try Parser.rlimits(["nofile=1024", "nofile=2048"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("duplicate ulimit type")
        }
    }

    @Test
    func testUlimitParserInvalidValue() throws {
        #expect {
            _ = try Parser.rlimits(["nofile=abc"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid ulimit value")
        }
    }

    @Test
    func testUlimitParserEmptyArray() throws {
        let result = try Parser.rlimits([])
        #expect(result.isEmpty)
    }

    @Test
    func testUlimitParserZeroValue() throws {
        let result = try Parser.rlimits(["core=0"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_CORE")
        #expect(result[0].soft == 0)
        #expect(result[0].hard == 0)
    }

    @Test
    func testUlimitParserLargeValues() throws {
        let result = try Parser.rlimits(["nproc=\(UInt64.max - 1):\(UInt64.max)"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_NPROC")
        #expect(result[0].soft == UInt64.max - 1)
        #expect(result[0].hard == UInt64.max)
    }
}
