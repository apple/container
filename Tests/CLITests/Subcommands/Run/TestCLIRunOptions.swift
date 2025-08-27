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

import AsyncHTTPClient
import ContainerClient
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Testing

class TestCLIRunCommand: CLITest {
    func runHelper(name: String, testCase: () throws -> Void) {
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
        }
        do {
            try testCase()
            try doStop(name: name)
            try doRemove(name: name)
        } catch {
            // Try and glean some info from the boot log.
            if let bootLog = try? doLogs(name: name, boot: true) {
                Issue.record("failed to run container (Error: \(error)) (Boot log: \(bootLog))")
            } else {
                Issue.record("failed to run container (Error: \(error))")
            }
        }
    }

    func runHelperAsync(name: String, testCase: () async throws -> Void) async {
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
        }
        do {
            try await testCase()
            try doStop(name: name)
            try doRemove(name: name)
        } catch {
            // Try and glean some info from the boot log.
            if let bootLog = try? doLogs(name: name, boot: true) {
                Issue.record("failed to run container (Error: \(error)) (Boot log: \(bootLog))")
            } else {
                Issue.record("failed to run container (Error: \(error))")
            }
        }
    }

    @Test func testRunCommand() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            try doLongRun(name: name, args: [])
            let _ = try doExec(name: name, cmd: ["date"])
        }
    }

    @Test func testRunCommandCWD() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let expectedCWD = "/tmp"
            try doLongRun(name: name, args: ["--cwd", expectedCWD])

            var output = try doExec(name: name, cmd: ["pwd"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == expectedCWD, "expected current working directory to be \(expectedCWD), instead got \(output)")
        }
    }

    @Test func testRunCommandEnv() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let envData = "FOO=bar"
            try doLongRun(name: name, args: ["--env", envData])

            let inspectResp = try inspectContainer(name)
            #expect(
                inspectResp.configuration.initProcess.environment.contains(envData),
                "environment variable \(envData) not set in container configuration")
        }
    }

    @Test func testRunCommandEnvFile() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
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

            let inspectResp = try inspectContainer(name)
            #expect(
                inspectResp.configuration.initProcess.environment.contains(envData),
                "environment variable \(envData) not set in container configuration")
        }
    }

    @Test func testRunCommandUserIDGroupID() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let uid = "10"
            let gid = "100"
            try doLongRun(name: name, args: ["--uid", uid, "--gid", gid])

            var output = try doExec(name: name, cmd: ["id"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            try #expect(output.contains(Regex("uid=\(uid).*?gid=\(gid).*")), "invalid user/group id, got \(output)")
        }
    }

    @Test func testRunCommandUser() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let user = "nobody"
            try doLongRun(name: name, args: ["--user", user])

            var output = try doExec(name: name, cmd: ["whoami"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == user, "expected user \(user), got \(output)")
        }
    }

    @Test func testRunCommandCPUs() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let cpus = "2"
            try doLongRun(name: name, args: ["--cpus", cpus])

            var output = try doExec(name: name, cmd: ["nproc"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == cpus, "expected \(cpus), instead got \(output)")
        }
    }

    @Test func testRunCommandMemory() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let expectedMBs = 1024
            try doLongRun(name: name, args: ["--memory", "\(expectedMBs)M"])

            let inspectResp = try inspectContainer(name)
            let actualInBytes = inspectResp.configuration.resources.memoryInBytes
            #expect(actualInBytes == expectedMBs.mib(), "expected \(expectedMBs.mib()) bytes, instead got \(actualInBytes) bytes")
        }
    }

    @Test func testRunCommandMount() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
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

            var output = try doExec(name: name, cmd: ["cat", "\(targetContainerPath)/\(tempFile.lastPathComponent)"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == testData, "expected file with content '\(testData)', instead got '\(output)'")
        }
    }

    @Test func testRunCommandUnixSocketMount() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
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

            let output = try doExec(name: name, cmd: ["ls", "-alh", "woo"])
            let splitOutput = output.components(separatedBy: .whitespaces)
            #expect(splitOutput.count > 0, "expected split output of 'ls -alh' to be at least 1, instead got \(splitOutput.count)")

            let perms = splitOutput[0]
            let firstChar = perms[perms.startIndex]
            #expect(firstChar == "s", "expected file in guest to be of type socket, instead got '\(firstChar)'")
        }
    }

    @Test func testRunCommandTmpfs() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let targetContainerPath = "/tmp/testtmpfs"
            let expectedFilesystem = "tmpfs"
            try doLongRun(name: name, args: ["--tmpfs", targetContainerPath])

            let output = try doExec(name: name, cmd: ["df", targetContainerPath])
            let lines = output.split(separator: "\n")
            #expect(lines.count == 2, "expected only two rows of output, instead got \(lines.count)")
            let words = lines[1].split(separator: " ")
            #expect(words.count > 1, "expected information to contain multiple words, got \(words.count)")
            #expect(words[0].lowercased() == expectedFilesystem, "expected filesystem type to be \(expectedFilesystem), instead got \(output)")
        }
    }

    @Test func testRunCommandOSArch() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let os = "linux"
            let arch = "amd64"
            let expectedArch = "x86_64"
            try doLongRun(name: name, args: ["--os", os, "--arch", arch])

            var output = try doExec(name: name, cmd: ["uname", "-sm"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            #expect(output == "\(os) \(expectedArch)", "expected container to use '\(os) \(expectedArch)', instead got '\(output)'")
        }
    }

    @Test func testRunCommandVolume() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
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

            var output = try doExec(name: name, cmd: ["cat", "\(targetContainerPath)/\(volumeFile.lastPathComponent)"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == testData, "expected file with content '\(testData)', instead got '\(output)'")
        }
    }

    @Test func testRunCommandCidfile() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let filePath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                try? FileManager.default.removeItem(at: filePath)
            }
            try doLongRun(name: name, args: ["--cidfile", filePath.path()])

            let actualID = try String(contentsOf: filePath, encoding: .utf8)
            #expect(actualID == name, "expected container ID '\(name!)', instead got '\(actualID)'")
        }
    }

    @Test func testRunCommandNoDNS() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            try doLongRun(name: name, args: ["--no-dns"])

            #expect(throws: (any Error).self) {
                try doExec(name: name, cmd: ["cat", "/etc/resolv.conf"])
            }
        }
    }

    @Test func testRunCommandDNS() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let dns = "8.8.8.8"
            try doLongRun(name: name, args: ["--dns", dns])

            var output = try doExec(name: name, cmd: ["cat", "/etc/resolv.conf"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = output.split(separator: " ")
            #expect(words.count == 2, "expected 'nameserver \(dns)', instead got '\(output)'")
            #expect(words[1].lowercased() == dns, "expected 'nameserver \(dns)', instead got '\(output)'")

        }
    }

    @Test func testRunCommandDNSDomain() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let dnsDomain = "example.com"
            try doLongRun(name: name, args: ["--dns-domain", dnsDomain])

            let output = try doExec(name: name, cmd: ["cat", "/etc/resolv.conf"])
            let lines = output.split(separator: "\n")
            #expect(lines.count == 2, "expected two lines of info in /etc/resolv.conf, got \(output)")
            let words = lines[1].split(separator: " ")
            #expect(words.count == 2, "expected 'domain \(dnsDomain)', instead got '\(lines[1])'")
            #expect(words[0].lowercased() == "domain", "expected entry to list domain, instead got '\(words[0])'")
            #expect(words[1].lowercased() == dnsDomain, "expected '\(dnsDomain)' search domain, instead got '\(words[1])'")
        }
    }

    @Test func testRunCommandDNSSearch() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let dnsSearch = "test.com"
            try doLongRun(name: name, args: ["--dns-search", dnsSearch])

            let output = try doExec(name: name, cmd: ["cat", "/etc/resolv.conf"])
            let lines = output.split(separator: "\n")
            #expect(lines.count == 2, "expected two lines of info in /etc/resolv.conf, got \(output)")
            let words = lines[1].split(separator: " ")
            #expect(words.count == 2, "expected 'search \(dnsSearch)', instead got '\(lines[1])'")
            #expect(words[0].lowercased() == "search", "expected entry to list search domains, instead got '\(words[0])'")
            #expect(words[1].lowercased() == dnsSearch, "expected '\(dnsSearch)' search domain, instead got '\(words[1])'")
        }
    }

    @Test func testRunDefaultHostsEntries() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            try doLongRun(name: name)

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
        }
    }

    @Test func testRunCommandDNSOption() throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        runHelper(name: name) {
            let dnsOption = "debug"
            try doLongRun(name: name, args: ["--dns-option", dnsOption])

            let output = try doExec(name: name, cmd: ["cat", "/etc/resolv.conf"])
            let lines = output.split(separator: "\n")
            #expect(lines.count == 2, "expected two lines of info in /etc/resolv.conf, got \(output)")
            let words = lines[1].split(separator: " ")
            #expect(words.count == 2, "expected 'opts \(dnsOption)', instead got '\(lines[1])'")
            #expect(words[0].lowercased() == "opts", "expected entry to list dns options, instead got '\(words[0])'")
            #expect(words[1].lowercased() == dnsOption, "expected option '\(dnsOption)', instead got '\(words[1])'")
        }
    }

    @Test func testForwardTCP() async throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        await runHelperAsync(name: name) {
            let retries = 10
            let retryDelaySeconds = Int64(3)
            let proxyIp = "127.0.0.1"
            let proxyPort = UInt16.random(in: 50000..<55000)
            let serverPort = UInt16.random(in: 55000..<60000)
            try doLongRun(
                name: name,
                image: "docker.io/library/python:alpine",
                args: ["--publish", "\(proxyIp):\(proxyPort):\(serverPort)/tcp"],
                containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(serverPort)"]
            )

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
        }
    }
}
