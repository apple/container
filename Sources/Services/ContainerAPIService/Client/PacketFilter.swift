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
import DNSServer
import Foundation
import SystemPackage

public struct PacketFilter {
    public static let anchor = "com.apple.container"
    public static let defaultConfigPath = FilePath("/etc/pf.conf")
    public static let defaultAnchorsPath = FilePath("/etc/pf.anchors")

    private let configPath: FilePath
    private let anchorsPath: FilePath

    public init(configPath: FilePath = Self.defaultConfigPath, anchorsPath: FilePath = Self.defaultAnchorsPath) {
        self.configPath = configPath
        self.anchorsPath = anchorsPath
    }

    public func createRedirectRule(from: IPAddress, to: IPAddress, domain: DNSName) throws {
        guard type(of: from) == type(of: to) else {
            throw ContainerizationError(.invalidArgument, message: "protocol does not match: \(from) vs. \(to)")
        }

        let fm: FileManager = FileManager.default

        let anchorPath = self.anchorsPath.appending(Self.anchor)

        let inet: String
        switch from {
        case .v4: inet = "inet"
        case .v6: inet = "inet6"
        }
        let redirectRule = "rdr \(inet) from any to \(from.description) -> \(to.description) # \(domain.pqdn)"

        var content = ""
        if fm.fileExists(atPath: anchorPath.string) {
            content = try String(contentsOfFile: anchorPath.string, encoding: .utf8)
        } else {
            try addAnchorToConfig()
        }

        var lines = content.components(separatedBy: .newlines)
        if !content.contains(redirectRule) {
            lines.insert(redirectRule, at: lines.endIndex - 1)
        }

        try lines.joined(separator: "\n").write(toFile: anchorPath.string, atomically: true, encoding: .utf8)
    }

    public func removeRedirectRule(from: IPAddress, to: IPAddress, domain: DNSName) throws {
        guard type(of: from) == type(of: to) else {
            throw ContainerizationError(.invalidArgument, message: "protocol does not match: \(from) vs. \(to)")
        }

        let fm: FileManager = FileManager.default

        let anchorPath = self.anchorsPath.appending(Self.anchor)

        let inet: String
        switch from {
        case .v4: inet = "inet"
        case .v6: inet = "inet6"
        }
        let redirectRule = "rdr \(inet) from any to \(from.description) -> \(to.description) # \(domain.pqdn)"

        guard fm.fileExists(atPath: anchorPath.string) else {
            return
        }

        let content = try String(contentsOfFile: anchorPath.string, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        let removedLines = lines.filter { l in
            l != redirectRule
        }

        if removedLines == [""] {
            try fm.removeItem(atPath: anchorPath.string)
            try removeAnchorFromConfig()
        } else {
            try removedLines.joined(separator: "\n").write(toFile: anchorPath.string, atomically: true, encoding: .utf8)
        }
    }

    private func addAnchorToConfig() throws {
        let fm: FileManager = FileManager.default

        let anchorPath = self.anchorsPath.appending(Self.anchor)

        /* PF requires strict ordering of anchors:
           scrub-anchor, nat-anchor, rdr-anchor, dummynet-anchor, anchor, load anchor
         */
        let anchorKeywords = ["scrub-anchor", "nat-anchor", "rdr-anchor", "dummynet-anchor", "anchor", "load anchor"]
        let loadAnchorText = "load anchor \"\(Self.anchor)\" from \"\(anchorPath.string)\""

        var content: String = ""
        var lines: [String] = []
        if fm.fileExists(atPath: self.configPath.string) {
            content = try String(contentsOfFile: self.configPath.string, encoding: .utf8)
        }
        lines = content.components(separatedBy: .newlines)

        for (i, keyword) in anchorKeywords[..<(anchorKeywords.endIndex - 1)].enumerated() {
            let anchorText = "\(keyword) \"\(Self.anchor)\""

            if content.contains(anchorText) {
                continue
            }

            let idx = lines.firstIndex { l in
                anchorKeywords[i...].map { k in l.starts(with: k) }.contains(true)
            }
            lines.insert(anchorText, at: idx ?? lines.endIndex - 1)
        }

        if !content.contains(loadAnchorText) {
            lines.insert(loadAnchorText, at: lines.endIndex - 1)
        }

        do {
            try lines.joined(separator: "\n").write(toFile: self.configPath.string, atomically: true, encoding: .utf8)
        } catch {
            throw ContainerizationError(.invalidState, message: "failed to write \"\(self.configPath.string)\"")
        }
    }

    private func removeAnchorFromConfig() throws {
        let fm: FileManager = FileManager.default

        guard fm.fileExists(atPath: configPath.string) else {
            return
        }

        let content = try String(contentsOfFile: configPath.string, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        let removedLines = lines.filter { l in !l.contains(Self.anchor) }

        do {
            try removedLines.joined(separator: "\n").write(toFile: configPath.string, atomically: true, encoding: .utf8)
        } catch {
            throw ContainerizationError(.invalidState, message: "failed to write \"\(configPath.string)\"")
        }
    }

    public func reinitialize() throws {
        let null = FileHandle.nullDevice

        let checkProcess = Foundation.Process()
        var checkStatus: Int32
        checkProcess.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        checkProcess.arguments = ["-n", "-f", configPath.string]
        checkProcess.standardOutput = null
        checkProcess.standardError = null

        do {
            try checkProcess.run()
        } catch {
            throw ContainerizationError(.internalError, message: "pfctl rule check exec failed: \"\(error)\"")
        }

        checkProcess.waitUntilExit()
        checkStatus = checkProcess.terminationStatus
        guard checkStatus == 0 else {
            throw ContainerizationError(.internalError, message: "invalid pf config \"\(configPath.string)\"")
        }

        let reloadProcess = Foundation.Process()
        var reloadStatus: Int32

        reloadProcess.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        reloadProcess.arguments = ["-f", configPath.string]
        reloadProcess.standardOutput = null
        reloadProcess.standardError = null

        do {
            try reloadProcess.run()
        } catch {
            throw ContainerizationError(.internalError, message: "pfctl reload exec failed: \"\(error)\"")
        }
        reloadProcess.waitUntilExit()
        reloadStatus = reloadProcess.terminationStatus
        guard reloadStatus == 0 else {
            throw ContainerizationError(.invalidState, message: "pfctl -f \"\(configPath.string)\" failed with status \(reloadStatus)")
        }
    }
}
