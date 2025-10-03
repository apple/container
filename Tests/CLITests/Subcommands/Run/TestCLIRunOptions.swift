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

import AsyncHTTPClient
import ContainerClient
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Testing

class TestCLIRunCommand: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    private func getLowercasedTestName() -> String {
        getTestName().lowercased()
    }

    @Test func testRunCommand() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: [])
            defer {
                try? doStop(name: name)
            }
            let _ = try doExec(name: name, cmd: ["date"])
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandCWD() throws {
        do {
            let name = getTestName()
            let expectedCWD = "/tmp"
            try doLongRun(name: name, args: ["--cwd", expectedCWD])
            defer {
                try? doStop(name: name)
            }
            var output = try doExec(name: name, cmd: ["pwd"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == expectedCWD, "expected current working directory to be \(expectedCWD), instead got \(output)")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandEnv() throws {
        do {
            let name = getTestName()
            let envData = "FOO=bar"
            try doLongRun(name: name, args: ["--env", envData])
            defer {
                try? doStop(name: name)
            }
            let inspectResp = try inspectContainer(name)
            #expect(
                inspectResp.configuration.initProcess.environment.contains(envData),
                "environment variable \(envData) not set in container configuration")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandEnvFile() throws {
        do {
            let name = getTestName()
            let envData = "FOO=bar"
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.env")
            guard FileManager.default.createFile(atPath: tempFile.path(), contents: Data(envData.utf8)) else {
                Issue.record("failed to create temporary file \(tempFile.path())")
                return
            }
            defer {
                try? FileManager.default.removeItem(at: tempFile)
            }
            try doLongRun(name: name, args: ["--env-file", tempFile.path()])
            defer {
                try? doStop(name: name)
            }
            let inspectResp = try inspectContainer(name)
            #expect(
                inspectResp.configuration.initProcess.environment.contains(envData),
                "environment variable \(envData) not set in container configuration")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandUserIDGroupID() throws {
        do {
            let name = getTestName()
            let uid = "10"
            let gid = "100"
            try doLongRun(name: name, args: ["--uid", uid, "--gid", gid])
            defer {
                try? doStop(name: name)
            }

            var output = try doExec(name: name, cmd: ["id"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            try #expect(output.contains(Regex("uid=\(uid).*?gid=\(gid).*")), "invalid user/group id, got \(output)")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandUser() throws {
        do {
            let name = getTestName()
            let user = "nobody"
            try doLongRun(name: name, args: ["--user", user])
            defer {
                try? doStop(name: name)
            }
            var output = try doExec(name: name, cmd: ["whoami"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == user, "expected user \(user), got \(output)")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandCPUs() throws {
        do {
            let name = getTestName()
            let cpus = "2"
            try doLongRun(name: name, args: ["--cpus", cpus])
            defer {
                try? doStop(name: name)
            }
            var output = try doExec(name: name, cmd: ["nproc"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == cpus, "expected \(cpus), instead got \(output)")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandMemory() throws {
        do {
            let name = getTestName()
            let expectedMBs = 1024
            try doLongRun(name: name, args: ["--memory", "\(expectedMBs)M"])
            defer {
                try? doStop(name: name)
            }
            let inspectResp = try inspectContainer(name)
            let actualInBytes = inspectResp.configuration.resources.memoryInBytes
            #expect(actualInBytes == expectedMBs.mib(), "expected \(expectedMBs.mib()) bytes, instead got \(actualInBytes) bytes")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandMount() throws {
        do {
            let name = getTestName()
            let targetContainerPath = "/tmp/testmount"
            let testData = "hello world"
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: tempFile.path(), contents: Data(testData.utf8)) else {
                Issue.record("failed to create temporary file \(tempFile.path())")
                return
            }
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }
            try doLongRun(name: name, args: ["--mount", "type=virtiofs,source=\(tempDir.path()),target=\(targetContainerPath),readonly"])
            defer {
                try? doStop(name: name)
            }
            var output = try doExec(name: name, cmd: ["cat", "\(targetContainerPath)/\(tempFile.lastPathComponent)"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == testData, "expected file with content '\(testData)', instead got '\(output)'")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandUnixSocketMount() throws {
        do {
            let name = getTestName()
            let socketPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

            let socketType = try UnixType(path: socketPath.path, unlinkExisting: true)
            let socket = try Socket(type: socketType, closeOnDeinit: true)
            try socket.listen()
            defer {
                try? socket.close()
                try? FileManager.default.removeItem(at: socketPath)
            }

            try doLongRun(
                name: name,
                args: ["-v", "\(socketPath.path):/woo"]
            )
            defer {
                try? doStop(name: name)
            }
            let output = try doExec(name: name, cmd: ["ls", "-alh", "woo"])
            let splitOutput = output.components(separatedBy: .whitespaces)
            #expect(splitOutput.count > 0, "expected split output of 'ls -alh' to be at least 1, instead got \(splitOutput.count)")

            let perms = splitOutput[0]
            let firstChar = perms[perms.startIndex]
            #expect(firstChar == "s", "expected file in guest to be of type socket, instead got '\(firstChar)'")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandTmpfs() throws {
        do {
            let name = getTestName()
            let targetContainerPath = "/tmp/testtmpfs"
            let expectedFilesystem = "tmpfs"
            try doLongRun(name: name, args: ["--tmpfs", targetContainerPath])
            defer {
                try? doStop(name: name)
            }
            let output = try doExec(name: name, cmd: ["df", targetContainerPath])
            let lines = output.split(separator: "\n")
            #expect(lines.count == 2, "expected only two rows of output, instead got \(lines.count)")
            let words = lines[1].split(separator: " ")
            #expect(words.count > 1, "expected information to contain multiple words, got \(words.count)")
            #expect(words[0].lowercased() == expectedFilesystem, "expected filesystem type to be \(expectedFilesystem), instead got \(output)")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandOSArch() throws {
        do {
            let name = getLowercasedTestName()
            let os = "linux"
            let arch = "amd64"
            let expectedArch = "x86_64"
            try doLongRun(name: name, args: ["--os", os, "--arch", arch])
            defer {
                try? doStop(name: name)
            }
            var output = try doExec(name: name, cmd: ["uname", "-sm"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            #expect(output == "\(os) \(expectedArch)", "expected container to use '\(os) \(expectedArch)', instead got '\(output)'")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandPlatform() throws {
        do {
            let name = getTestName()
            let os = "linux"
            let platform = "linux/amd64"
            let expectedArch = "x86_64"
            try doLongRun(name: name, args: ["--platform", platform])
            defer {
                try? doStop(name: name)
            }
            var output = try doExec(name: name, cmd: ["uname", "-sm"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            #expect(output == "\(os) \(expectedArch)", "expected container to use '\(os) \(expectedArch)', instead got '\(output)'")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandVolume() throws {
        do {
            let name = getTestName()
            let targetContainerPath = "/tmp/testvolume"
            let testData = "one small step"
            let volume = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
            let volumeFile = volume.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: volumeFile.path(), contents: Data(testData.utf8)) else {
                Issue.record("failed to create file at \(volumeFile)")
                return
            }
            defer {
                try? FileManager.default.removeItem(at: volume)
            }
            try doLongRun(name: name, args: ["--volume", "\(volume.path):\(targetContainerPath)"])
            defer {
                try? doStop(name: name)
            }
            var output = try doExec(name: name, cmd: ["cat", "\(targetContainerPath)/\(volumeFile.lastPathComponent)"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == testData, "expected file with content '\(testData)', instead got '\(output)'")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandCidfile() throws {
        do {
            let name = getTestName()
            let filePath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                try? FileManager.default.removeItem(at: filePath)
            }
            try doLongRun(name: name, args: ["--cidfile", filePath.path()])
            defer {
                try? doStop(name: name)
            }
            let actualID = try String(contentsOf: filePath, encoding: .utf8)
            #expect(actualID == name, "expected container ID '\(name)', instead got '\(actualID)'")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandNoDNS() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: ["--no-dns"])
            defer {
                try? doStop(name: name)
            }
            #expect(throws: (any Error).self) {
                try doExec(name: name, cmd: ["cat", "/etc/resolv.conf"])
            }
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandDefaultResolvConf() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, args: [])
            defer {
                try? doStop(name: name)
            }

            let output = try doExec(name: name, cmd: ["cat", "/etc/resolv.conf"])
            let actualLines = output.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .map { $0.components(separatedBy: .whitespaces) }
                .map { $0.joined(separator: " ") }

            let inspectOutput = try inspectContainer(name)
            let ip = String(inspectOutput.networks[0].address.split(separator: "/")[0])
            let ipv4Address = try IPv4Address(ip)
            let expectedNameserver = IPv4Address(fromValue: ipv4Address.prefix(prefixLength: 24).value + 1).description
            let defaultDomain = try getDefaultDomain()
            let expectedLines: [String] = [
                "nameserver \(expectedNameserver)",
                defaultDomain.map { "domain \($0)" },
            ].compactMap { $0 }

            #expect(expectedLines == actualLines)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunCommandNonDefaultResolvConf() throws {
        do {
            let expectedDns: String = "8.8.8.8"
            let expectedDomain = "example.com"
            let expectedSearch = "test.com"
            let expectedOption = "debug"
            let name = getTestName()
            try doLongRun(
                name: name,
                args: [
                    "--dns", expectedDns,
                    "--dns-domain", expectedDomain,
                    "--dns-search", expectedSearch,
                    "--dns-option", expectedOption,
                ])
            defer {
                try? doStop(name: name)
            }

            let output = try doExec(name: name, cmd: ["cat", "/etc/resolv.conf"])
            let actualLines = output.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .map { $0.components(separatedBy: .whitespaces) }
                .map { $0.joined(separator: " ") }

            let expectedLines: [String] = [
                "nameserver \(expectedDns)",
                "domain \(expectedDomain)",
                "search \(expectedSearch)",
                "options \(expectedOption)",
            ]
            #expect(expectedLines == actualLines)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testRunDefaultHostsEntries() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name)
            defer {
                try? doStop(name: name)
            }

            let inspectOutput = try inspectContainer(name)
            let ip = String(inspectOutput.networks[0].address.split(separator: "/")[0])

            let output = try doExec(name: name, cmd: ["cat", "/etc/hosts"])
            let lines = output.split(separator: "\n")

            let expectedEntries = [("127.0.0.1", "localhost"), (ip, name)]

            for (i, line) in lines.enumerated() {
                let words = line.split(separator: " ").map { String($0) }
                #expect(words.count >= 2, "expected /etc/hosts entry to have 2 or more entries")
                let expected = expectedEntries[i]
                #expect(expected.0 == words[0], "expected /etc/hosts entries IP to be \(expected.0), instead got \(words[0])")
                #expect(expected.1 == words[1], "expected /etc/hosts entries host to be \(expected.1), instead got \(words[1])")
            }
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    @Test func testForwardTCP() async throws {
        let retries = 10
        let retryDelaySeconds = Int64(3)
        do {
            let name = getLowercasedTestName()
            let proxyIp = "127.0.0.1"
            let proxyPort = UInt16.random(in: 50000..<55000)
            let serverPort = UInt16.random(in: 55000..<60000)
            try doLongRun(
                name: name,
                image: "docker.io/library/python:alpine",
                args: ["--publish", "\(proxyIp):\(proxyPort):\(serverPort)/tcp"],
                containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(serverPort)"])
            defer {
                try? doStop(name: name)
            }

            let url = "http://\(proxyIp):\(proxyPort)"
            var request = HTTPClientRequest(url: url)
            request.method = .GET
            let config = HTTPClient.Configuration(proxy: nil)
            let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)
            defer { _ = client.shutdown() }
            var retriesRemaining = retries
            var success = false
            while !success && retriesRemaining > 0 {
                do {
                    let response = try await client.execute(request, timeout: .seconds(retryDelaySeconds))
                    try #require(response.status == .ok)
                    success = true
                } catch {
                    print("request to \(url) failed, error \(error)")
                    try await Task.sleep(for: .seconds(retryDelaySeconds))
                }
                retriesRemaining -= 1
            }
            #expect(success, "Request to \(url) failed after \(retries - retriesRemaining) retries")
            try doStop(name: name)
        } catch {
            Issue.record("failed to run container \(error)")
            return
        }
    }

    func getDefaultDomain() throws -> String? {
        let (output, err, status) = try run(arguments: ["system", "property", "get", "dns.domain"])
        try #require(status == 0, "default DNS domain retrieval returned status \(status): \(err)")
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOutput == "" {
            return nil
        }

        return trimmedOutput
    }
}
