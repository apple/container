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

public struct PacketFilter {
    public static let anchor = "com.apple.container"
    public static let defaultConfigPath = URL(filePath: "/etc/pf.conf")
    public static let defaultAnchorsPath = URL(filePath: "/etc/pf.anchors")

    private let configURL: URL
    private let anchorsURL: URL

    public init(configURL: URL = Self.defaultConfigPath, anchorsURL: URL = Self.defaultAnchorsPath) {
        self.configURL = configURL
        self.anchorsURL = anchorsURL
    }

    public func createRedirectRule(from: IPAddress, to: IPAddress) throws {
        guard type(of: from) == type(of: to) else {
            throw ContainerizationError(.invalidArgument, message: "protocol does not match: \(from) vs. \(to)")
        }

        let fm: FileManager = FileManager.default

        let anchorURL = self.anchorsURL.appending(path: Self.anchor)

        let inet: String
        switch from {
        case .v4: inet = "inet"
        case .v6: inet = "inet6"
        }
        let redirectRule = "rdr \(inet) from any to \(from.description) -> \(to.description)"

        var content = ""
        var lines: [String] = []
        if fm.fileExists(atPath: anchorURL.path) {
            content = try String(contentsOfFile: anchorURL.path, encoding: .utf8)
            lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }

        if !content.contains(redirectRule) {
            lines.append(redirectRule + "\n")
        } else {
            lines.append("")
        }

        do {
            try lines.joined(separator: "\n").write(toFile: anchorURL.path, atomically: true, encoding: .utf8)
        } catch {
            throw ContainerizationError(.invalidState, message: "failed to write \"\(anchorURL.path)\"")
        }
    }

    public func removeRedirectRule(from: IPAddress, to: IPAddress) throws {
        guard type(of: from) == type(of: to) else {
            throw ContainerizationError(.invalidArgument, message: "protocol does not match: \(from) vs. \(to)")
        }

        let fm: FileManager = FileManager.default

        let anchorURL = self.anchorsURL.appending(path: Self.anchor)

        let inet: String
        switch from {
        case .v4: inet = "inet"
        case .v6: inet = "inet6"
        }
        let redirectRule = "rdr \(inet) from any to \(from.description) -> \(to.description)"

        guard fm.fileExists(atPath: anchorURL.path) else {
            return
        }

        let content = try String(contentsOfFile: anchorURL.path, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

        var removedLines = lines.filter { l in
            l != redirectRule
        }
        removedLines.append("")

        do {
            try removedLines.joined(separator: "\n").write(toFile: anchorURL.path, atomically: true, encoding: .utf8)
        } catch {
            throw ContainerizationError(.invalidState, message: "failed to write \"\(anchorURL.path)\"")
        }
    }

    public func updateConfig() throws {
        let fm: FileManager = FileManager.default

        let anchorURL = self.anchorsURL.appending(path: Self.anchor)

        /* PF requires strict ordering of anchors:
           scrub-anchor, nat-anchor, rdr-anchor, dummynet-anchor, anchor, load anchor
         */
        let anchorKeywords = ["scrub-anchor", "nat-anchor", "rdr-anchor", "dummynet-anchor", "anchor", "load anchor"]
        let loadAnchorText = "load anchor \"\(Self.anchor)\" from \"\(anchorURL.path)\""

        var content: String = ""
        var lines: [String] = []
        if fm.fileExists(atPath: self.configURL.path) {
            content = try String(contentsOfFile: self.configURL.path, encoding: .utf8)
            lines = content.components(separatedBy: .newlines)
        }

        for (i, keyword) in anchorKeywords[..<(anchorKeywords.endIndex - 1)].enumerated() {
            let anchorText = "\(keyword) \"\(Self.anchor)\""

            if content.contains(anchorText) {
                continue
            }

            let idx = lines.firstIndex { l in
                anchorKeywords[i...].map { k in l.starts(with: k) }.contains(true)
            }
            lines.insert(anchorText, at: idx ?? lines.endIndex)
        }

        if !content.contains(loadAnchorText) {
            lines.append(loadAnchorText + "\n")
        }

        do {
            try lines.joined(separator: "\n").write(toFile: self.configURL.path, atomically: true, encoding: .utf8)
        } catch {
            throw ContainerizationError(.invalidState, message: "failed to write \"\(self.configURL.path)\"")
        }
    }

    public func reinitialize() throws {
        do {
            let pfctl = Foundation.Process()
            let null = FileHandle.nullDevice
            var status: Int32

            pfctl.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
            pfctl.arguments = ["-n", "-f", configURL.path]
            pfctl.standardOutput = null
            pfctl.standardError = null

            try pfctl.run()
            pfctl.waitUntilExit()
            status = pfctl.terminationStatus
            guard status == 0 else {
                throw ContainerizationError(.internalError, message: "invalid pf config \"\(configURL.path)\"")
            }
        }

        do {
            let pfctl = Foundation.Process()
            let null = FileHandle.nullDevice
            var status: Int32

            pfctl.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
            pfctl.arguments = ["-f", configURL.path]
            pfctl.standardOutput = null
            pfctl.standardError = null

            try pfctl.run()
            pfctl.waitUntilExit()
            status = pfctl.terminationStatus
            guard status == 0 else {
                throw ContainerizationError(.invalidState, message: "pfctl -f \"\(configURL.path)\" failed")
            }
        }
    }
}
